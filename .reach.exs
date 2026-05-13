# Reach architecture policy for ex_vrp.
# Layers are listed roughly outer (entry-point) → inner (NIF leaf).
[
  layers: [
    api: ["ExVrp"],
    solver: [
      "ExVrp.Solver",
      "ExVrp.IteratedLocalSearch",
      "ExVrp.MinimiseFleet"
    ],
    search: [
      "ExVrp.Neighbourhood",
      "ExVrp.NeighbourhoodParams",
      "ExVrp.PenaltyManager",
      "ExVrp.PerturbationManager",
      "ExVrp.StoppingCriteria"
    ],
    model: [
      "ExVrp.Model",
      "ExVrp.Client",
      "ExVrp.ClientGroup",
      "ExVrp.Depot",
      "ExVrp.Route",
      "ExVrp.Solution",
      "ExVrp.Trip",
      "ExVrp.VehicleType",
      "ExVrp.SameVehicleGroup",
      "ExVrp.ScheduledVisit",
      "ExVrp.DurationSegment",
      "ExVrp.LoadSegment"
    ],
    io: ["ExVrp.Read"],
    utility: [
      "ExVrp.RNG",
      "ExVrp.DynamicBitset",
      "ExVrp.RingBuffer",
      "ExVrp.Statistics",
      "ExVrp.Errors"
    ],
    # NIF leaf — no outbound deps; anything may call into it.
    native: ["ExVrp.Native"],
    runtime: ["ExVrp.Application"]
  ],
  deps: [
    forbidden: [
      {:model, :solver},
      {:model, :search},
      {:model, :io},
      {:io, :solver},
      {:io, :search},
      {:utility, :solver},
      {:utility, :search},
      {:utility, :model},
      {:utility, :io},
      {:native, :api},
      {:native, :solver},
      {:native, :search},
      {:native, :model},
      {:native, :io},
      {:native, :utility}
    ]
  ],
  source: [
    forbidden_modules: [],
    forbidden_files: []
  ],
  calls: [
    forbidden: []
  ],
  effects: [
    allowed: []
  ],
  boundaries: [
    public: [],
    internal: [],
    internal_callers: []
  ],
  risk: [
    changed: [
      many_direct_callers: 5,
      wide_transitive_callers: 10,
      branch_heavy: 8,
      high_risk_reason_count: 3
    ]
  ],
  candidates: [
    thresholds: [
      mixed_effect_count: 2,
      branchy_function_branches: 8,
      high_risk_direct_callers: 4
    ],
    limits: [
      per_kind: 20,
      representative_calls: 10,
      representative_calls_per_edge: 3
    ]
  ],
  clone_analysis: [
    provider: :ex_dna,
    min_mass: 30,
    min_similarity: 1.0,
    max_clones: 50
  ],
  smells: [
    fixed_shape_map: [
      min_keys: 3,
      min_occurrences: 3,
      evidence_limit: 10
    ],
    behaviour_candidate: [
      min_modules: 3,
      min_callbacks: 3,
      module_display_limit: 8,
      callback_display_limit: 8
    ]
  ],
  tests: [
    hints: []
  ]
]
