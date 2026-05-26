{
  "_generated_by": "meta-harness v1.0.0 (/meta-harness:build)",
  "_generated_at": "{{generated_at}}",
  "_project_name": "{{project_name}}",
  "_note": "JSON does not allow comments. The fields prefixed with underscore are provenance metadata, not Claude Code settings. Claude Code ignores unknown top-level keys; these are safe to keep, or delete them if you prefer a strict file.",
  "model": "inherit",
  "permissions": {
    "allow": [
      "Read",
      "Edit",
      "Glob",
      "Grep",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(git status:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(jq:*)"
    ],
    "deny": [
      "Bash(rm -rf /:*)",
      "Bash(rm -rf ~:*)",
      "Bash(rm -rf $HOME:*)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(curl:* | sh)",
      "Bash(curl:* | bash)",
      "Bash(wget:* | sh)",
      "Bash(wget:* | bash)",
      "Read(./.env*)",
      "Read(./id_rsa*)",
      "Read(./*.pem)",
      "Read(./*.key)",
      "Read(./credentials.*)",
      "Read(./secrets.*)"
    ]
  }
}
