require 'spec_helper'
require 'bosh/stemcell/stemcell_packager'
require 'bosh/stemcell/stage_collection'
require 'bosh/stemcell/stage_runner'
require 'bosh/stemcell/definition'
require 'bosh/stemcell/archive_filename'
require 'yaml'

describe Bosh::Stemcell::StemcellPackager do
  subject(:packager) do
    Bosh::Stemcell::StemcellPackager.new(
        definition: definition,
        version: version,
        work_path: work_dir,
        tarball_path: tarball_dir,
        disk_size: disk_size,
        runner: runner,
        collection: collection,
    )
  end

  class FakeInfrastructure < Bosh::Stemcell::Infrastructure::Base
    def additional_cloud_properties
      { 'fake_infra_specific_property' => 'some_value'}
    end
  end

  let(:runner) { instance_double('Bosh::Stemcell::StageRunner') }
  let(:collection) { Bosh::Stemcell::StageCollection.new(definition) }
  let(:env) { {} }
  let(:infrastructure) do
    FakeInfrastructure.new(
      name: 'fake_infra',
      hypervisor: 'fake_hypervisor',
      default_disk_size: -1,
      disk_formats: ['qcow2', 'raw'],
      stemcell_formats: ['stemcell-format-a', 'stemcell-format-b']
    )
  end
  let(:operating_system) { Bosh::Stemcell::OperatingSystem.for('ubuntu', 'jammy') }

  let(:definition) do
    Bosh::Stemcell::Definition.new(
      infrastructure,
      'fake_hypervisor',
      operating_system
    )
  end

  let(:version) { 1234 }
  let(:release_tarball_path) { '/path/to/release.tgz' }
  let(:os_image_tarball_path) { '/path/to/os-img.tgz' }
  let(:gem_components) { double('Bosh::Dev::GemComponents', build_release_gems: nil) }
  let(:collection) do
    instance_double(
      'Bosh::Stemcell::StageCollection',
      extract_operating_system_stages: [:extract_stage],
      build_stemcell_image_stages: [:build_stage],
      package_stemcell_stages: [:package_stage],
      agent_stages: [:agent_stage],
    )
  end
  let(:tmp_dir) { Dir.mktmpdir }
  let(:work_dir) { File.join(tmp_dir, 'stemcell-work').tap {|f| FileUtils.mkdir_p(f)} }
  let(:tarball_dir) { File.join(tmp_dir, 'tarballs').tap {|f| FileUtils.mkdir_p(f)} }
  let(:disk_size) { 4096 }

  before do
    FileUtils.mkdir_p(File.join(work_dir, 'stemcell'))

    allow(runner).to receive(:configure_and_apply) do
      image_file = File.join(work_dir, 'stemcell/image')
      raise 'this step fails if the image already exists!' if File.exist?(image_file)
      File.write(image_file, "i'm an image!")
    end
    packages = File.join(work_dir, 'stemcell/packages.txt')
    File.write(packages, 'i am stemcell dpkg_l')
    dev_tools_file_list = File.join(work_dir, 'stemcell/dev_tools_file_list.txt')
    File.write(dev_tools_file_list, 'i am dev_tools_file_list')
    spdx_sbom = File.join(work_dir, 'stemcell/sbom.spdx.json')
    File.write(spdx_sbom, 'i am spdx sbom')
    cyclonedx_sbom = File.join(work_dir, 'stemcell/sbom.cdx.json')
    File.write(cyclonedx_sbom, 'i am cyclonedx sbom')
  end
  after { FileUtils.rm_rf(tmp_dir) }

  describe '#package' do
    let(:disk_format) { 'qcow2' }

    it 'invokes packaging stages appropriate for the disk format' do
      allow(collection).to receive(:package_stemcell_stages).with('qcow2').and_return([:package_qcow2])
      expect(runner).to receive(:configure_and_apply).with([:package_qcow2])
      packager.package(disk_format)
    end

    it 'writes a stemcell.MF containing metadata' do
      packager.package('raw')

      actual_manifest = YAML.load_file(File.join(work_dir, 'stemcell/stemcell.MF'))

      architecture = 'x86_64'

      expect(actual_manifest).to eq({
        'name' => 'bosh-fake_infra-fake_hypervisor-ubuntu-jammy-go_agent-raw',
        'version' => '1234',
        'bosh_protocol' => 1,
        'api_version' => 3,
        'sha1' => 'c1ebdefc3f8282a9d7d47803fb5030b61ffc793d', # SHA-1 of image above
        'operating_system' => 'ubuntu-jammy',
        'stemcell_formats' => ['stemcell-format-a', 'stemcell-format-b'],
        'cloud_properties' => {
          'name' => 'bosh-fake_infra-fake_hypervisor-ubuntu-jammy-go_agent-raw',
          'version' => '1234',
          'infrastructure' => 'fake_infra',
          'hypervisor' => 'fake_hypervisor',
          'disk' => 4096,
          'disk_format' => 'raw',
          'container_format' => 'bare',
          'os_type' => 'linux',
          'os_distro' => 'ubuntu',
          'architecture' => architecture,
          'fake_infra_specific_property' => 'some_value'
        }
      })
    end

    it 'returns the path of the created tarball' do
      expect(packager.package(disk_format)).to eq(
        File.join(tarball_dir, "bosh-stemcell-1234-fake_infra-fake_hypervisor-ubuntu-jammy-go_agent.tgz"))
    end

    context 'if an image already exist in the stemcell dir' do
      before do
        FileUtils.mkdir_p(File.join(work_dir, 'stemcell'))
        File.write(File.join(work_dir, 'stemcell/image'), 'bad image!')
      end

      it 'deletes it first so that applying the package_stemcell_stages doesnt blow up' do
        expect { packager.package(disk_format) }.not_to raise_error
      end
    end

    it 'archives the working dir' do
      packager.package(disk_format)

      tarball_path = File.join(tarball_dir, "bosh-stemcell-1234-fake_infra-fake_hypervisor-ubuntu-jammy-go_agent.tgz")
      expect(File.exist?(tarball_path)).to eq(true)

      stemcell_contents_path = File.join(tmp_dir, 'stemcell-contents')
      FileUtils.mkdir_p(stemcell_contents_path)
      Dir.chdir(stemcell_contents_path) do
        Open3.capture3("tar xfz #{tarball_path}")
      end

      extracted_image_path = File.join(stemcell_contents_path, 'image')
      expect(File.exist?(extracted_image_path)).to eq(true)
      expect(File.read(extracted_image_path)).to eq("i'm an image!")

      actual_manifest = File.read(File.join(work_dir, 'stemcell/stemcell.MF'))
      extracted_stemcell_mf = File.join(stemcell_contents_path, 'stemcell.MF')
      expect(File.exist?(extracted_stemcell_mf)).to eq(true)
      expect(File.read(extracted_stemcell_mf)).to eq(actual_manifest)
    end

    it 'stemcell tarball contains files in proper order' do
      packager.package(disk_format)

      tarball_path = File.join(tarball_dir, "bosh-stemcell-1234-fake_infra-fake_hypervisor-ubuntu-jammy-go_agent.tgz")
      expect(File.exist?(tarball_path)).to eq(true)

      stdout, _, _ = Open3.capture3("tar tf #{tarball_path}")
      expect(stdout).to eq(
'stemcell.MF
packages.txt
dev_tools_file_list.txt
image
sbom.spdx.json
sbom.cdx.json
'
      )
    end

    it 'fails if necessary files are not found in the stemcell working directory' do
      _, _, status = Open3.capture3("rm -f #{work_dir}/stemcell/dev_tools_file_list.txt #{work_dir}/stemcell/packages.txt")
      expect(status.success?).to be(true)

      expect{ packager.package(disk_format) }.to raise_error(/Files are missing from stemcell directory: packages.txt dev_tools_file_list.txt/)
    end

    it 'fails if additional files are found in the stemcell working director' do
      File.open("#{work_dir}/stemcell/my-extra-file", 'w') {}

      expect{ packager.package(disk_format) }.to raise_error(/Extra files found in stemcell directory: my-extra-file/)
    end

    context 'when disk format is not the default for the infrastructure' do
      let(:disk_format) { 'raw' }

      it 'archives the working dir with a different tarball name' do
        packager.package(disk_format)

        tarball_path = File.join(tarball_dir, "bosh-stemcell-1234-fake_infra-fake_hypervisor-ubuntu-jammy-go_agent-raw.tgz")
        expect(File.exist?(tarball_path)).to eq(true)
      end
    end

    context 'when packaging a non standard os variant' do
      let(:operating_system) { Bosh::Stemcell::OperatingSystem.for('ubuntu', 'FOO-fips') }

      it 'archives the working dir with a different tarball name' do
        packager.package(disk_format)
        tarball_path = File.join(tarball_dir, "bosh-stemcell-1234-fake_infra-fake_hypervisor-ubuntu-FOO-fips-go_agent.tgz")
        expect(File.exist?(tarball_path)).to eq(true)
      end

      it 'writes the variant into the stemcell.MF' do
        packager.package('raw')

        actual_manifest = YAML.load_file(File.join(work_dir, 'stemcell/stemcell.MF'))

        expect(actual_manifest['name']).to eq('bosh-fake_infra-fake_hypervisor-ubuntu-FOO-fips-go_agent-raw')
        expect(actual_manifest['operating_system']).to eq('ubuntu-FOO')
      end
    end
  end
end
