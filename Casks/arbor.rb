cask "arbor" do
  version "1.0.40"
  sha256 "a75d14da301f428b522c453f34d0fce1d2b7e8b645904fb816bd7e98d3eb839a"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
