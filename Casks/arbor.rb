cask "arbor" do
  version "1.0.28"
  sha256 "35549506a05b8c50e0799f08943ab1074f8d7e6acd20f61af8b2826b52859805"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
