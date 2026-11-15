.PHONY: test lint package

test:
	.venv/bin/pytest -q

lint:
	shellcheck bootstrap-server.sh bootstrap-openwrt.sh openwrt-agent/*.sh openwrt-agent/files/router-support openwrt-agent/files/router-support.init deploy/*.sh scripts/*.sh
	node --check frontend/app.js
	node --check frontend/login.js
	python3 -m compileall -q backend tests

package:
	./scripts/package-release.sh

