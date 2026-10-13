defmodule Hermitscale.Workflows.Nodes.Support.Reply.V1 do
  @moduledoc "Delivers an exact reviewed support reply with retained mutation reconciliation."
  use Hermitscale.Workflows.Nodes.External,
    id: "support.reply",
    version: 1,
    kind: :step,
    expr: [:case_id, :body, :outcome, :deployment_id, :defect_evidence_id, :review_id],
    params: [
      case_id: [type: :string, required: true],
      body: [type: :string, required: true],
      outcome: [
        type:
          {:in,
           ~w(explanation workaround reproduced_defect proposed_fix verified_deployment blocked)},
        required: true
      ],
      deployment_id: [type: :string],
      defect_evidence_id: [type: :string],
      review_id: [type: :string]
    ]
end
