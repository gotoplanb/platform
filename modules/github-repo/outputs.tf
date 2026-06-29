output "full_name" {
  description = "owner/repo."
  value       = github_repository.this.full_name
}

output "html_url" {
  description = "Repo URL."
  value       = github_repository.this.html_url
}

output "ruleset_id" {
  description = "Default-branch ruleset id (null when unmanaged)."
  value       = var.manage_ruleset ? github_repository_ruleset.main[0].ruleset_id : null
}

output "managed_labels" {
  description = "Label names managed authoritatively."
  value       = keys(var.labels)
}
