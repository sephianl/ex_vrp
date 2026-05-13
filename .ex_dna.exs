%{
  min_mass: 25,
  min_occurrences: 3,
  ignore: ["lib/my_app_web/templates/**"],
  excluded_macros: [:schema, :pipe_through, :plug],
  normalize_pipes: true
}
