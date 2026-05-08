defmodule CodePuppyControl.Repo do
  use Ecto.Repo,
    otp_app: :code_puppy_control,
    adapter: Ecto.Adapters.SQLite3
end
