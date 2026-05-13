# Tailscale ACL — manages the tailnet policy file as code.
#
# Bootstrap (one-time, before first `terraform apply`):
#
#   1. Create an OAuth client at
#      https://login.tailscale.com/admin/settings/oauth.
#      Required scope: "Policy File" → Write. Other scopes can stay
#      off. (Tailscale's UI used to call this scope `acl`; it's now
#      `policy_file:write` in the OAuth spec.)
#
#   2. Store the credentials in 1Password:
#        Vault:  Infrastructure
#        Title:  "Tailscale Terraform OAuth"
#        Fields:
#          - username:   <OAuth client ID>
#          - credential: <OAuth client secret>
#
#   3. The first `terraform apply` will *write* the checked-in
#      tailscale-acl.hujson over whatever policy currently lives in
#      the admin console (no import — this is a create with
#      `overwrite_existing_content = true`, which the API requires
#      when there's already content not written by the same client).
#      Make sure the HuJSON in the repo matches the live policy
#      *before* applying, or use `tofu state import` if you need a
#      true import. Any console-side drift after this point will be
#      reverted on the next apply.
#
# Day-to-day: edit tailscale-acl.hujson, then `terraform apply`.
# The provider validates the HuJSON server-side before applying, so a
# broken policy fails at plan/apply time instead of locking us out.

data "onepassword_item" "tailscale_terraform_oauth" {
  vault = "Infrastructure"
  title = "Tailscale Terraform OAuth"
}

provider "tailscale" {
  oauth_client_id     = data.onepassword_item.tailscale_terraform_oauth.username
  oauth_client_secret = data.onepassword_item.tailscale_terraform_oauth.credential
  # "-" means "the tailnet associated with the OAuth client" — works
  # for personal accounts without hardcoding the email/org name.
  tailnet = "-"
  # `scopes` intentionally omitted so the provider just requests the
  # scopes the OAuth client was generated with. Pinning to a specific
  # string (`acl` vs `policy_file:write`) couples this config to the
  # Tailscale OAuth scope-naming churn — the client itself already
  # constrains what's grantable.
}

resource "tailscale_acl" "policy" {
  acl                        = file("${path.module}/tailscale-acl.hujson")
  overwrite_existing_content = true
}
