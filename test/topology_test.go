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
	"os"
	"os/exec"
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

// render runs `terragrunt render --format json` for a stack with a controlled topology env
// and returns (providerContents, stateBucket).
func render(t *testing.T, stack string, env map[string]string) (string, string) {
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

func TestTopologyRouting(t *testing.T) {
	hub := hubAccount(t)

	topologies := []struct {
		name    string
		env     map[string]string
		role    string // expected assume-role name for cross-account stacks; "" = no assume anywhere
		nonprod string
		prod    string
	}{
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

	for _, topo := range topologies {
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
