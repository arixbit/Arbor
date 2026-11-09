cask "arbor" do
  version "1.0.35"
  sha256 "500139a8ee9eb21a51244473459a4d740687a6a1c1be44b0862f83d316c6747d"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
