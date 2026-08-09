VERCEL := ./node_modules/.bin/vercel

.PHONY: install build vercel-deploy

install:
	npm ci

build:
	npm run build

# Builds with Vercel locally, then uploads only the prebuilt production output.
vercel-deploy: install
	$(VERCEL) pull --yes --environment=production
	$(VERCEL) build --prod
	$(VERCEL) deploy --prebuilt --prod
