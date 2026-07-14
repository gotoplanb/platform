// Topology routing contract (platform#50): as the repo evolves, every stack must keep
// targeting the right account, with the right assume-role, in all three topologies.
//
// These tests are FAST and MUTATION-FREE: `terragrunt render --format json` resolves the
// root config (generated provider + remote_state) without touching any member account —
// only one STS GetCallerIdentity for the hub. Member ids are FAKE, so this runs anywhere
// with read-only credentials (AWS_PROFILE=watch-ro locally, the plan role in CI).
//
//	cd test && go test -run TestTopologyRouting -v
package test

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	fakeNonprod = "111111111111"
	fakeProd    = "222222222222"
)

// renderDoc runs `terragrunt render --format json` for a stack with a controlled topology env.
func renderDoc(t *testing.T, stack string, env map[string]string) map[string]any {
	t.Helper()
	cmd := exec.Command("terragrunt", "render", "--format", "json")
	cmd.Dir = "../" + stack
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	out, err := cmd.Output()
	if err != nil {
		var stderr string
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = string(ee.Stderr)
		}
		require.NoError(t, err, "render %s failed: %s", stack, stderr)
	}

	var doc map[string]any
	require.NoError(t, json.Unmarshal(out, &doc), "render %s: bad json", stack)
	return doc
}

// renderInputs returns a stack's resolved inputs — what the module would actually be called with.
func renderInputs(t *testing.T, stack string, env map[string]string) map[string]any {
	t.Helper()
	inputs, _ := dig(renderDoc(t, stack, env), "inputs").(map[string]any)
	require.NotNil(t, inputs, "render %s: no inputs", stack)
	return inputs
}

// render returns (providerContents, stateBucket) for a stack.
func render(t *testing.T, stack string, env map[string]string) (string, string) {
	t.Helper()
	doc := renderDoc(t, stack, env)

	provider, _ := dig(doc, "generate", "provider", "contents").(string)
	require.NotEmpty(t, provider, "render %s: no generated provider", stack)
	bucket, _ := firstString(
		dig(doc, "remote_state", "backend_config", "bucket"),
		dig(doc, "remote_state", "config", "bucket"),
	)
	require.NotEmpty(t, bucket, "render %s: no state bucket", stack)
	return provider, bucket
}

func dig(m any, keys ...string) any {
	cur := m
	for _, k := range keys {
		asMap, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = asMap[k]
	}
	return cur
}

func firstString(vals ...any) (string, bool) {
	for _, v := range vals {
		if s, ok := v.(string); ok && s != "" {
			return s, true
		}
	}
	return "", false
}

func hubAccount(t *testing.T) string {
	t.Helper()
	cfg, err := awsconfig.LoadDefaultConfig(context.Background())
	require.NoError(t, err)
	ident, err := sts.NewFromConfig(cfg).GetCallerIdentity(context.Background(), &sts.GetCallerIdentityInput{})
	require.NoError(t, err, "need AWS credentials (read-only is enough) for STS GetCallerIdentity")
	return *ident.Account
}

// One representative stack per routing class in the root terragrunt map.
var routingClasses = []struct {
	stack string
	class string // management | nonprod | prod
}{
	{"account/github-oidc", "management"},
	{"watch/us-east-1/ecr", "nonprod"}, // foundation → nonprod
	{"watch/us-east-1/staging/network", "nonprod"},
	{"watch/us-east-1/prod/network", "prod"},
	{"member-ci/nonprod", "nonprod"},
	{"member-ci/prod", "prod"},
	// The provisioner role + permissions boundary (ADR-044) must land INSIDE each member — a
	// boundary in the wrong account fences nothing, and the estate's roles would fail to create.
	{"member-iam/nonprod", "nonprod"},
	{"member-iam/prod", "prod"},
	{"account/provisioner", "management"},
	// The GitHub federation entry, one owner per federating account (platform#57).
	{"account/oidc-provider", "management"},
	{"member-oidc/nonprod", "nonprod"},
}

// Stacks that own an ACCOUNT-GLOBAL name — something AWS permits exactly one of per account, and
// which we therefore may create from exactly one stack per account:
//
//	the GitHub OIDC provider  (one per URL per account)
//	watch-provisioner + watch-boundary  (named per project, identical in every account, by design)
//
// Every one of these stacks gates creation on a `create` input, because in the single-account
// topology they all route to the SAME account and would otherwise fight over the same names. That
// is the bug this table exists to prevent from coming back (platform#57, platform#58).
var globalNameOwners = []struct {
	stack string
	class string
	owns  string // the account-global name(s) this stack creates
}{
	{"account/oidc-provider", "management", "github-oidc-provider"},
	{"member-oidc/nonprod", "nonprod", "github-oidc-provider"},
	{"account/provisioner", "management", "provisioner-role+boundary"},
	{"member-iam/nonprod", "nonprod", "provisioner-role+boundary"},
	{"member-iam/prod", "prod", "provisioner-role+boundary"},
}

func expectedAccount(class, hub, nonprod, prod string) string {
	switch class {
	case "nonprod":
		if nonprod != "" {
			return nonprod
		}
	case "prod":
		if prod != "" {
			return prod
		}
	}
	return hub // management class, or single-account fallback
}

type topology struct {
	name    string
	env     map[string]string
	role    string // expected assume-role name for cross-account stacks; "" = no assume anywhere
	nonprod string
	prod    string
}

func topologies() []topology {
	return []topology{
		{
			name: "single-account",
			env: map[string]string{
				"WATCH_NONPROD_ACCOUNT_ID": "", "WATCH_PROD_ACCOUNT_ID": "", "WATCH_MEMBER_ROLE_NAME": "",
			},
		},
		{
			name: "two-member-new-org(default-role)",
			env: map[string]string{
				"WATCH_NONPROD_ACCOUNT_ID": fakeNonprod, "WATCH_PROD_ACCOUNT_ID": fakeProd, "WATCH_MEMBER_ROLE_NAME": "",
			},
			role: "OrganizationAccountAccessRole", nonprod: fakeNonprod, prod: fakeProd,
		},
		{
			name: "two-member-existing-org(custom-role)",
			env: map[string]string{
				"WATCH_NONPROD_ACCOUNT_ID": fakeNonprod, "WATCH_PROD_ACCOUNT_ID": fakeProd,
				"WATCH_MEMBER_ROLE_NAME": "AWSControlTowerExecution",
			},
			role: "AWSControlTowerExecution", nonprod: fakeNonprod, prod: fakeProd,
		},
	}
}

func TestTopologyRouting(t *testing.T) {
	hub := hubAccount(t)

	for _, topo := range topologies() {
		for _, rc := range routingClasses {
			t.Run(topo.name+"/"+rc.stack, func(t *testing.T) {
				provider, bucket := render(t, rc.stack, topo.env)

				want := expectedAccount(rc.class, hub, topo.nonprod, topo.prod)
				assert.Contains(t, provider, fmt.Sprintf("allowed_account_ids = [%q]", want),
					"stack must target the %s account in %s", rc.class, topo.name)

				cross := want != hub
				if cross {
					wantArn := fmt.Sprintf("arn:aws:iam::%s:role/%s", want, topo.role)
					assert.Contains(t, provider, wantArn, "cross-account stack must assume the member role")
				} else {
					assert.NotContains(t, provider, "assume_role", "same-account stack must not assume")
				}

				// State ALWAYS stays in the hub bucket, every topology (ADR-020).
				assert.Equal(t, "watch-tfstate-"+hub, bucket)
			})
		}
	}
}

// An IAM OIDC provider is account-global: exactly one per URL per account. It must therefore have
// exactly one OWNER, and the owner must be a stack whose whole job is to own it — not whichever
// module happens to want a federated role. Two modules used to create one each; that survived the
// two-member topologies only because the two landed in different accounts, and it collided in
// single-account (and would collide with an adopter's existing GitHub federation). platform#57.
func TestOnlyTheOwnerModuleDeclaresTheOIDCProvider(t *testing.T) {
	var offenders []string
	err := filepath.WalkDir("../modules", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Ext(path) != ".tf" {
			return err
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !strings.Contains(string(body), `resource "aws_iam_openid_connect_provider"`) {
			return nil
		}
		if filepath.Base(filepath.Dir(path)) != "oidc-provider" {
			offenders = append(offenders, path)
		}
		return nil
	})
	require.NoError(t, err)
	assert.Empty(t, offenders,
		"only modules/oidc-provider may declare an OIDC provider; consume the ARN instead (platform#57)")
}

// ...and in no topology may two stacks create the same account-global name in the same account.
// This is the check that would have caught both bugs with no apply and no AWS mutation: they were
// invisible in the two-member topologies (the owners landed in different accounts) and only
// surfaced as a 409 mid-apply in single-account.
func TestOneOwnerPerAccountGlobalName(t *testing.T) {
	hub := hubAccount(t)

	for _, topo := range topologies() {
		t.Run(topo.name, func(t *testing.T) {
			// (account, global name) -> the stacks that would create it
			creators := map[string]map[string][]string{}

			for _, o := range globalNameOwners {
				create, ok := renderInputs(t, o.stack, topo.env)["create"].(bool)
				require.Truef(t, ok, "%s must gate its account-global names on a `create` input", o.stack)
				if !create {
					continue
				}
				acct := expectedAccount(o.class, hub, topo.nonprod, topo.prod)
				if creators[acct] == nil {
					creators[acct] = map[string][]string{}
				}
				creators[acct][o.owns] = append(creators[acct][o.owns], o.stack)
			}

			for acct, byName := range creators {
				for name, stacks := range byName {
					assert.Lenf(t, stacks, 1,
						"account %s would get %d × %q from %v — an account-global name has exactly one owner",
						acct, len(stacks), name, stacks)
				}
			}

			// The estate must still be COMPLETE, not merely collision-free: every account we write to
			// needs a provisioner, and the pipeline's account needs a federation entry or
			// watch-ci-trigger trusts nothing.
			for _, class := range []string{"management", "nonprod", "prod"} {
				acct := expectedAccount(class, hub, topo.nonprod, topo.prod)
				assert.NotEmptyf(t, creators[acct]["provisioner-role+boundary"],
					"%s account (%s) has no provisioner role — nothing can apply there without admin", class, acct)
			}
			pipelineAcct := expectedAccount("nonprod", hub, topo.nonprod, topo.prod)
			assert.NotEmpty(t, creators[pipelineAcct]["github-oidc-provider"],
				"the pipeline account (%s) has no GitHub federation entry — watch-ci-trigger cannot be assumed", pipelineAcct)

			// Prod federates GitHub nowhere. Nothing in GitHub reaches prod directly; the nonprod
			// pipeline does, by assuming watch-prod-deploy.
			if topo.prod != "" {
				assert.Empty(t, creators[topo.prod]["github-oidc-provider"], "prod must have no GitHub OIDC provider")
			}
		})
	}
}

// The WATCH_PROJECT rename knob must move the state prefix without touching routing.
func TestProjectRenameKnob(t *testing.T) {
	hub := hubAccount(t)
	provider, bucket := render(t, "account/github-oidc", map[string]string{
		"WATCH_NONPROD_ACCOUNT_ID": "", "WATCH_PROD_ACCOUNT_ID": "", "WATCH_PROJECT": "acme",
	})
	assert.Equal(t, "acme-tfstate-"+hub, bucket)
	assert.Contains(t, provider, `project    = "acme"`, "default project tag follows the knob")
	assert.True(t, strings.Contains(provider, hub), "still targets the hub")
}
