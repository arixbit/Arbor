cask "arbor" do
  version "1.0.39"
  sha256 "96e8d6ed6067aac7a81e8464ba38ce3362e2841ebfbaa8c93b025aff0233cbae"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
