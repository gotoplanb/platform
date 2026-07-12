// Real Terratest for member-access/ (platform#50): apply the module into the NONPROD member
// account, prove the hub can actually assume the minted role, then destroy. This is the
// classic Terratest shape (apply → assert against real AWS → destroy) kept to one tiny,
// free, fast module — the full estate is exercised by `make live`, not by tests.
//
// Opt-in (creates real IAM, needs hub admin creds that can assume into the member):
//
//	AWS_PROFILE=watch-bootstrap RUN_MEMBER_ACCESS_TEST=1 go test -run TestMemberAccessRole -v
//
// or `make test-member-access`.
package test

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func TestMemberAccessRole(t *testing.T) {
	if os.Getenv("RUN_MEMBER_ACCESS_TEST") != "1" {
		t.Skip("set RUN_MEMBER_ACCESS_TEST=1 (and hub admin creds) to run the real apply test")
	}
	member := os.Getenv("WATCH_NONPROD_ACCOUNT_ID")
	require.NotEmpty(t, member, "WATCH_NONPROD_ACCOUNT_ID must be set (source .env)")

	ctx := context.Background()
	hubCfg, err := awsconfig.LoadDefaultConfig(ctx)
	require.NoError(t, err)
	hubSts := sts.NewFromConfig(hubCfg)
	hubIdent, err := hubSts.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	require.NoError(t, err)
	hub := *hubIdent.Account

	// Stand in for "the member's own credentials" (as an adopter would have): assume the
	// org role into the member and hand those creds to tofu.
	orgRole := fmt.Sprintf("arn:aws:iam::%s:role/OrganizationAccountAccessRole", member)
	assumed, err := hubSts.AssumeRole(ctx, &sts.AssumeRoleInput{
		RoleArn: &orgRole, RoleSessionName: strPtr("terratest-member-access"),
	})
	require.NoError(t, err, "need to be able to assume into the member (hub admin creds)")

	roleName := fmt.Sprintf("PlatformAccessTT-%d", time.Now().Unix())
	tf := &terraform.Options{
		TerraformDir:    "../member-access",
		TerraformBinary: "tofu",
		Vars: map[string]any{
			"hub_account_id": hub,
			"role_name":      roleName,
		},
		EnvVars: map[string]string{
			"AWS_ACCESS_KEY_ID":     *assumed.Credentials.AccessKeyId,
			"AWS_SECRET_ACCESS_KEY": *assumed.Credentials.SecretAccessKey,
			"AWS_SESSION_TOKEN":     *assumed.Credentials.SessionToken,
			"AWS_PROFILE":           "",
		},
		// keep the adopter dir's local state pristine: isolate this run in a workspace
		BackendConfig: map[string]any{},
	}
	terraform.WorkspaceSelectOrNew(t, tf, "terratest")
	defer func() {
		terraform.Destroy(t, tf)
		terraform.WorkspaceDelete(t, tf, "terratest")
	}()
	terraform.InitAndApply(t, tf)

	roleArn := terraform.Output(t, tf, "role_arn")
	require.Contains(t, roleArn, roleName)

	// The contract: the HUB can assume the minted role (IAM is eventually consistent — retry).
	retry.DoWithRetry(t, "hub assumes minted role", 10, 3*time.Second, func() (string, error) {
		out, err := hubSts.AssumeRole(ctx, &sts.AssumeRoleInput{
			RoleArn: &roleArn, RoleSessionName: strPtr("terratest-verify"),
		})
		if err != nil {
			return "", err
		}
		// and the assumed identity really is in the member account
		memberCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider(
				*out.Credentials.AccessKeyId, *out.Credentials.SecretAccessKey, *out.Credentials.SessionToken,
			)))
		if err != nil {
			return "", err
		}
		ident, err := sts.NewFromConfig(memberCfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
		if err != nil {
			return "", err
		}
		if *ident.Account != member {
			return "", fmt.Errorf("assumed into %s, want %s", *ident.Account, member)
		}
		return "ok", nil
	})
}

func strPtr(s string) *string { return &s }
