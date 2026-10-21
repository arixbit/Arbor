cask "arbor" do
  version "1.0.20"
  sha256 "ea7def80609a7261c52004b0e60f9a1efdb6ac35612dc51d86d22223f7e26837"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
