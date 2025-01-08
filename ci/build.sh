#!/bin/sh

# Set baseURL only for preview builds on CloudFlare
# Production baseURL is configured in /hugo.yaml
if [ -z "$CF_PAGES" ] || [ "$CF_PAGES_BRANCH" = "main" ]; then
  hugo
else
  hugo --baseURL $CF_PAGES_URL
fi
