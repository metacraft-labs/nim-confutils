## Every test of confutils over a clispec description, in one binary, as
## ``tests/test_all.nim`` gathers the tests of a configuration type.

{.warning[UnusedImport]: off.}

import
  test_cs_m9_confutils_over_clispec,
  test_cs_m9_combine_signature_checked,
  test_cs_m4_precedence_and_origins,
  test_cs_m4_merge_rules,
  test_cs_m4_enforced_value_explained,
  test_cs_m4_default_never_overrides_file,
  test_cs_m4_unknown_key_rejected,
  test_cs_m4b_per_source_convention,
  test_cs_m4b_override_precedence,
  test_cs_m10_compat_rules_through_merge,
  test_cs_m10_classic_help,
  test_cs_m6_after_separator_through_confutils
