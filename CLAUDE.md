# gstack

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools.

Available gstack skills:

- /office-hours
- /plan-ceo-review
- /plan-eng-review
- /plan-design-review
- /design-consultation
- /design-shotgun
- /design-html
- /review
- /ship
- /land-and-deploy
- /canary
- /benchmark
- /browse
- /connect-chrome
- /qa
- /qa-only
- /design-review
- /setup-browser-cookies
- /setup-deploy
- /setup-gbrain
- /retro
- /investigate
- /document-release
- /document-generate
- /codex
- /cso
- /autoplan
- /plan-devex-review
- /devex-review
- /careful
- /freeze
- /guard
- /unfreeze
- /gstack-upgrade
- /learn

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec

## Design System

Always read DESIGN.md before making any visual or UI decision, on either
surface: the site in `docs/` and the SwiftUI app in `App/UI/`.

- Fonts, colours, spacing, radii, motion and the diagram grammar are defined
  there. Do not deviate without explicit user approval.
- Brand colour comes from tokens only. Never hardcode a green in Swift or CSS;
  the app reads `Brand.green` (backed by `AccentColor.colorset`).
- `--accent-lime` is a fill colour and fails contrast as text at every size.
  Green text uses `--brand-green`.
- Amber text under 14px uses `--net-text`, not `--net`.
- In QA or review mode, flag any code that does not match DESIGN.md, and check
  the "Open drift to fix" list before adding new visual code.
