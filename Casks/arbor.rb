cask "arbor" do
  version "1.0.19"
  sha256 "ba1cd6a923327c2ff4cd15e1096883b13d6cf381377cd7e602577c98040f279f"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
