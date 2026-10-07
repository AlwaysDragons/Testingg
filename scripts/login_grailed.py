"""Interactive login for grailed. Saves storage_state to the configured session file.

Run from host (needs a display for the headful browser):
    python -m scripts.login_grailed --handle grailed
"""
from scripts._login_common import cli

if __name__ == "__main__":
    cli("grailed")
