# Lets the tests import the API modules (main, access, guide) directly, and
# accepts the test client's host name ("testserver").
import os

os.environ.setdefault("API_ALLOWED_HOSTS", "testserver")
