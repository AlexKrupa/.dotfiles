#!/usr/bin/env bash
# Usage: npm-workspaces.sh <repo-dir>
# Branch `feat/auth-package` vs `main` (with origin). npm workspaces, no Gradle.
# Structure change (expect a module diagram):
#   new package @shop/auth, depends on @shop/shared
#   @shop/web -> @shop/auth  new edge
#   @shop/api -> @shop/auth  new edge
# Unchanged and not relevant: @shop/docs-site.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put package.json <<'EOF'
{
  "name": "shop",
  "private": true,
  "workspaces": ["packages/*"]
}
EOF

# pkg <name> <deps...> - writes packages/<name>/package.json with workspace dependencies.
pkg() {
  local name="$1"; shift
  local deps="" sep=""
  for d in "$@"; do deps+="$sep\"@shop/$d\": \"workspace:*\""; sep=", "; done
  put "packages/$name/package.json" <<EOF
{
  "name": "@shop/$name",
  "version": "1.0.0",
  "main": "src/index.ts",
  "dependencies": { $deps }
}
EOF
}

pkg shared
pkg api shared
pkg web shared
pkg docs-site

put packages/shared/src/index.ts <<'EOF'
export const API_URL = "https://api.shop.test";
EOF

put packages/api/src/index.ts <<'EOF'
import { API_URL } from "@shop/shared";

export function handle(path: string): string {
  return `${API_URL}${path}`;
}
EOF

put packages/web/src/index.ts <<'EOF'
import { API_URL } from "@shop/shared";

export function loginUrl(): string {
  return `${API_URL}/login`;
}
EOF

commit "Initial workspaces"
add_origin

git switch -q -c feat/auth-package

pkg auth shared
pkg api shared auth
pkg web shared auth

put packages/auth/src/index.ts <<'EOF'
import { API_URL } from "@shop/shared";

export function tokenUrl(): string {
  return `${API_URL}/oauth/token`;
}

export function isExpired(expiresAt: number, now: number = Date.now()): boolean {
  return now >= expiresAt;
}
EOF

put packages/api/src/index.ts <<'EOF'
import { isExpired } from "@shop/auth";
import { API_URL } from "@shop/shared";

export function handle(path: string, expiresAt: number): string {
  if (isExpired(expiresAt)) return "401";
  return `${API_URL}${path}`;
}
EOF

put packages/web/src/index.ts <<'EOF'
import { tokenUrl } from "@shop/auth";

export function loginUrl(): string {
  return tokenUrl();
}
EOF

commit "Extract auth into its own package"
