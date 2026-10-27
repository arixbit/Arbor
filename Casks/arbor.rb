cask "arbor" do
  version "1.0.26"
  sha256 "13cebc5847804e1f3b2da9fb3486fccf6242c2bc2fb12b1c859d71034f00481b"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
