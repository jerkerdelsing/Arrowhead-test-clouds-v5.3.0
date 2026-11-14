# Rust test cloud v5.3.0 (2026-11-12), see generator/README.md
PROJECT := arrowhead-v530-test-cloud-rust
.PHONY: build generate up down ps smoke smoke-security smoke-console test console-password
build:
	./generator/build.sh
generate:
	python3 generator/generate.py
up:
	./generator/deploy.sh up
down:
	./generator/deploy.sh down
ps:
	docker compose -f compose.json ps
smoke:
	python3 generator/smoke.py
smoke-security:
	python3 generator/smoke-security.py
smoke-console:
	python3 generator/smoke-console.py
test: smoke smoke-security smoke-console
# prints the console password from the macOS keychain (service arrowhead-console-$(PROJECT))
console-password:
	@security find-generic-password -s arrowhead-console-$(PROJECT) -w
