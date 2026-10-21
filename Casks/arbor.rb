cask "arbor" do
  version "1.0.22"
  sha256 "3f31a3d52c49b439b81d9d5b6290f5a4261572e3f7dbee5f931d9424545a4e5b"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
