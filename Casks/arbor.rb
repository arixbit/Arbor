cask "arbor" do
  version "1.0.21"
  sha256 "17b512602c9e6b02ad36ed4b20cc7010499f4e8caaf16c07980e83adc697f1fb"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
