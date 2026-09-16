# Moonhub Interface

## Composition

A 56px global header, a 224px context sidebar (64px collapsed), and a fluid main
workspace. The mobile sidebar becomes a dismissible, keyboard-accessible drawer.
Team and repository navigation are separate scopes. Page-local tabs never
duplicate the sidebar. Forms remain bounded; code and diffs use available width.

## Visual System

- Canvas and content: white; sidebar: cool neutral `#f7f8fa`.
- Text: `#20252c`; secondary text: `#5d6877`; border: `#e1e5eb`.
- Accent: `#1769d2`; success: `#1a7f37`; warning: `#986400`; danger: `#c12d39`.
- System sans for interface text, existing monospace faces for source and hashes.
- 14px body, 12px metadata, 24px page headings; zero letter spacing.
- 4/8px spacing rhythm, 6px control corners, 36px desktop controls.
- Sections are unframed. Lists use separators; only menus have elevation.
- Lucide icons, consistent 18px strokes, accessible labels on icon-only controls.

## Interaction

Primary actions are blue; ordinary actions are neutral; destructive actions
alone use red. Status includes text, never color alone. Invitation acceptance
and mail delivery are distinct states. Failed forms preserve entered data;
busy forms retain their submitted values and reject duplicate submissions.
Sidebar preference persists locally. Navigation remains usable without scripts.
