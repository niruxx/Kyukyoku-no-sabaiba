# sidebar/file_browser/panel

File browser panel mod. Displays an asset file tree with expand/collapse,
paginated loading, context menus, and file operations.

Uses Rust-side `list_server_directory` for directory listing.

## Component: `sidebar/file_browser/panel`

The mod entity itself becomes the panel UI root — its `Node`, `BackgroundColor`,
and `BorderColor` are patched on by this mod. The button parents the entity
directly under the sidebar entity, so no config fields are required.

## Dependencies
- Rust-side API: `list_server_directory(path, offset, limit)`
