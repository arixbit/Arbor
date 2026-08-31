cask "arbor" do
  version "1.0.18"
  sha256 "9cf88db00c98d48f054f1a216fb37c22186dfaf8f99f954b3f7c6ed1980b8996"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
