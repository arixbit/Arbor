cask "arbor" do
  version "1.0.37"
  sha256 "f38dd35ade3882350d4091308684ef1027ed757c7c3d8cbc91045f797aa09d5a"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
