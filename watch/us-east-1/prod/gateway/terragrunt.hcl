# Telemetry gateway for watch / prod (platform#19, ADR-016 §2). The app sidecars forward OTLP
# here; the gateway exports to the **managed vendor (Grafana Cloud)** — never a bundled Tempo
# slice (that stays staging-only per ADR-016/018). ha profile: private subnets, egress to the
# vendor via NAT. Endpoint / instance id / token come from ~/platform/.env via get_env (the token
# becomes a TF-managed SSM SecureString); all empty until .env is populated → the gateway falls
# back to a debug sink, so validate/plan work before the values exist.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    public_subnet_ids  = ["subnet-ma", "subnet-mb"]
    private_subnet_ids = ["subnet-pa", "subnet-pb"]
    app_sg_id          = "sg-app"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/gateway"
}

inputs = {
  name   = "${local.env.project}-${local.env.env}"
  region = local.env.region

  private_networking = local.env.private_networking
  vpc_id             = dependency.network.outputs.vpc_id
  public_subnet_ids  = dependency.network.outputs.public_subnet_ids
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  app_sg_id          = dependency.network.outputs.app_sg_id

  # prod → Grafana Cloud (ADR-016 §2). From ~/platform/.env; empty → debug sink until populated.
  vendor_endpoint      = get_env("GRAFANA_CLOUD_OTLP_ENDPOINT", "")
  vendor_auth_username = get_env("GRAFANA_CLOUD_INSTANCE_ID", "")
  vendor_token         = get_env("GRAFANA_CLOUD_TOKEN", "")

  # Tail-sampling (ADR-016 §3 / #23) is a gated var, left off pending enablement.
  desired_count = 1
}
