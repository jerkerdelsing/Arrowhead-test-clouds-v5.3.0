# Rust test cloud v5.3.0 (2026-11-12), see v530/README.md
PROJECT := arrowhead-v530-test-cloud-rust
.PHONY: build generate up down ps smoke smoke-security smoke-console test console-password
build:
	./v530/build.sh
generate:
	python3 v530/generate.py
up:
	./v530/deploy.sh up
down:
	./v530/deploy.sh down
ps:
	docker compose -f compose.json ps
smoke:
	python3 v530/smoke.py
smoke-security:
	python3 v530/smoke-security.py
smoke-console:
	python3 v530/smoke-console.py
test: smoke smoke-security smoke-console
# prints the console password from the macOS keychain (service arrowhead-console-$(PROJECT))
console-password:
	@security find-generic-password -s arrowhead-console-$(PROJECT) -w
