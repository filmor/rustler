defmodule RusterAdhocTest do
  use Rustler, otp_app: :rustler_tests

  # Rustler gets added automatically
  ~CARGO"""
  [dependencies]
  """

  defnif add_u32(a: u32, b: u32) -> u32 do
    a + b
  end

  ~NIF"""
  pub fn mul_u32(a: u32, b: u32) -> u32 {
    a * b
  }
  """

  # Init gets generated automatically

end
