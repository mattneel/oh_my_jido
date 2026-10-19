ExUnit.start()

if System.get_env("OH_MY_JIDO_PYTHON_EVAL") == "1" do
  # Snakepit orphan cleanup owns a logical host instance, not every local BEAM.
  data = Path.join(System.tmp_dir!(), "omj-snakepit-test-#{System.pid()}")
  Application.put_env(:snakepit, :instance_name, "oh_my_jido_test")
  Application.put_env(:snakepit, :instance_token, System.pid())
  Application.put_env(:snakepit, :data_dir, data)
  ExUnit.after_suite(fn _result -> File.rm_rf!(data) end)
end
