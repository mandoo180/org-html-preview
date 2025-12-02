# Agent Guidelines for org-html-preview

## Project Overview
Emacs Lisp package for live-previewing Org-mode files as HTML with WebSocket-based instant refresh.

## Build/Test Commands
- **Byte-compile**: `emacs -batch -f batch-byte-compile org-html-preview.el`
- **Load for testing**: `emacs -Q -l org-html-preview.el`
- **No formal test suite**: Manual testing required (open .org file, run `M-x org-html-preview-mode`)

## Code Style - Emacs Lisp
- **Lexical binding**: Always use `;;; -*- lexical-binding: t; -*-`
- **Naming**: Use `org-html-preview--` prefix for internal functions/vars, no prefix for public API
- **Documentation**: All functions need docstrings. Use `"""triple quotes"""` for multi-line
- **Customization**: User-facing vars use `defcustom` with `:type`, `:group` metadata
- **Error handling**: Use `condition-case` for network ops; prefer `error` for user-facing errors
- **Line length**: Keep under ~80 chars; break long format strings naturally
- **Comments**: Use `;;` for inline, `;;;` for section headers, `;;;;` for file headers

## Code Style - JavaScript (public/*.js)
- **Style**: Use strict mode, JSDoc comments, single quotes for strings
- **Variables**: `const` for immutable, `let` for mutable (no `var`)
- **Functions**: Arrow functions for callbacks, regular functions for top-level

## Key Architecture
- Servers (HTTP/WebSocket) shared across multiple buffers; stopped when all buffers close
- Temp HTML files in system temp dir; cleaned up when buffer unregistered
- Image paths rewritten during export to serve local files via HTTP server
