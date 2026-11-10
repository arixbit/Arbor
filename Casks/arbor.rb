cask "arbor" do
  version "1.0.36"
  sha256 "f51b3e3ba597d3d7507383323286e9db10edda3e756c2fc98d875c0f06bb33f5"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
