cask "arbor" do
  version "1.0.24"
  sha256 "5e06d3ef6d711491110e4112c598356f6c2154243349a73e57687be184fc2f62"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
