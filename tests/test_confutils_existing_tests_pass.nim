# nim-confutils
# M6: Dynamic Runtime Extensions
#
# Verification: the existing confutils test suite still passes with the
# runtime surface refactor (no regressions).
#
# This meta-test imports every pre-existing test module. Each module
# registers its own ``suite``/``test`` blocks with unittest2, so importing
# them here causes them to be run as part of this binary. If any pre-M6
# test fails or fails to compile, this verification fails along with it.
#
# Test_config_file is included: its toml/json serialization dependencies
# are pinned beside the rest of codetracer's stack (tests/config.nims).

{.warning[UnusedImport]: off.}

import
  test_ignore,
  test_cli_semantics,
  test_switch_semantics,
  test_config_file,
  test_envvar,
  test_parsecmdarg,
  test_pragma,
  test_qualified_ident

when defined(windows):
  import test_winreg
