defmodule ExVrp.Literature.Sample do
  @moduledoc """
  The default instance subset of each literature group: a stratified random sample, drawn
  once with a fixed seed and kept here so runs stay comparable over time.

  X and HFVRP take one instance from each of 25 size strata, MTVRPTWR five from each class
  and size, MDVRPTW one from each of ten strata of the PR11–PR24 set, Solomon and
  Homberger–Gehring two per class, and DIMACS every instance up to 500 clients. Stratifying
  on size and class makes a group's mean gap on the sample an unbiased estimate of its mean
  gap on the full set, which is what PyVRP publishes.
  """

  @names %{
    cvrp: ~w(X-n115-k10 X-n134-k13 X-n139-k10 X-n167-k10 X-n190-k8 X-n204-k19 X-n223-k34 X-n237-k14
             X-n251-k28 X-n280-k17 X-n298-k31 X-n322-k28 X-n344-k43 X-n367-k17 X-n411-k19 X-n429-k61
             X-n459-k26 X-n524-k153 X-n548-k50 X-n613-k62 X-n655-k131 X-n716-k35 X-n801-k40 X-n916-k207
             X-n957-k87),
    hfvrp: ~w(X1001-FSMF X106-FSMD X120-FSMF X143-FSMF X167-FSMF X186-FSMD X204-FSMD X223-HVRP X233-FSMD
              X261-HD X275-HVRP X294-HD X317-HVRP X331-FSMF X367-FSMFD X401-FSMFD X449-FSMFD X480-FSMD
              X502-FSMFD X561-FSMD X641-FSMFD X670-FSMF X716-FSMFD X783-HD X856-HVRP),
    mtvrptwr: ~w(C201R0.5 C204R0.25 C206R0.75 C207R0.25 C208R0.5 C2_2_01R0.25 C2_2_02R0.25 C2_2_03R0.75
                 C2_2_06R0.25 C2_2_06R0.5 R201R0.75 R202R0.75 R203R0.75 R204R0.75 R210R0.25 R2_2_02R0.25
                 R2_2_02R0.75 R2_2_04R0.75 R2_2_05R0.25 R2_2_10R0.75 RC201R0.75 RC202R0.25 RC204R0.5
                 RC206R0.25 RC208R0.25 RC2_2_02R0.25 RC2_2_03R0.25 RC2_2_04R0.5 RC2_2_06R0.25 RC2_2_08R0.5),
    mdvrptw: ~w(PR11B PR12A PR13B PR16A PR18B PR19A PR21A PR23A PR23B PR24A),
    solomon: ~w(C104 C107 C201 C202 R104 R111 R206 R208 RC101 RC103 RC201 RC207),
    hg200: ~w(C1_2_5 C1_2_7 C2_2_10 C2_2_9 R1_2_3 R1_2_4 R2_2_5 R2_2_8 RC1_2_7 RC1_2_9 RC2_2_5 RC2_2_6),
    dimacs: ~w(Loggi-n401-k23 Loggi-n501-k24 ORTEC-n242-k12 ORTEC-n323-k21 ORTEC-n405-k18 ORTEC-n455-k41)
  }

  @spec member?(atom(), String.t()) :: boolean()
  def member?(group, name), do: name in Map.fetch!(@names, group)
end
