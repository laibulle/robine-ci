defmodule Robine.Storage.Contracts.Download do
  @moduledoc "Verified artifact or cache content returned to an authorized adapter."
  @enforce_keys [:name, :content_type, :digest, :size, :content]
  defstruct [:name, :content_type, :digest, :size, :content]

  @type t :: %__MODULE__{
          name: String.t(),
          content_type: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          content: binary()
        }
end
