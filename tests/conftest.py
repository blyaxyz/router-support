import os

os.environ.setdefault("ROUTER_SUPPORT_BOOTSTRAP_TOKEN", "bootstrap-test-token")
os.environ.setdefault("ROUTER_SUPPORT_ENGINEER_TOKEN", "engineer-test-token")
os.environ.setdefault("ROUTER_SUPPORT_TOKEN_PEPPER", "test-pepper-not-for-production")
os.environ.setdefault("ROUTER_SUPPORT_SSH_HOST_KEY", "ssh-ed25519 AAAATESTHOSTKEY")
os.environ.setdefault("ROUTER_SUPPORT_PUBLIC_DOMAIN", "support.example.test")

