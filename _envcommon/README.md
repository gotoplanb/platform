# _envcommon

Shared, DRY stack definitions (one file per stack type — `network.hcl`, `data.hcl`,
`app.hcl`, …). A per-env stack `terragrunt.hcl` includes the root config + the matching
`_envcommon/<stack>.hcl`, then overlays env-specific inputs from its `env.hcl`.

Populated as each stack lands (platform#3 network, #4 data, #6 app, …). Empty for now —
platform#1 establishes only the state backend + the folder layout.
