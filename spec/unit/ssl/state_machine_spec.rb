require 'spec_helper'
require 'webmock/rspec'
require 'puppet_spec/files'

require 'puppet/ssl'

describe Puppet::SSL::StateMachine, unless: Puppet::Util::Platform.jruby? do
  include PuppetSpec::Files

  before(:each) do
    WebMock.disable_net_connect!

    allow_any_instance_of(Net::HTTP).to receive(:start)
    allow_any_instance_of(Net::HTTP).to receive(:finish)
  end

  let(:machine) { described_class.new }
  let(:cacert_pem) { cacert.to_pem }
  let(:cacert) { cert_fixture('ca.pem') }
  let(:cacerts) { [cacert] }

  let(:crl_pem) { crl.to_pem }
  let(:crl) { crl_fixture('crl.pem') }
  let(:crls) { [crl] }

  let(:private_key) { key_fixture('signed-key.pem') }
  let(:client_cert) { cert_fixture('signed.pem') }

  before(:each) do
    WebMock.disable_net_connect!

    allow_any_instance_of(Net::HTTP).to receive(:start)
    allow_any_instance_of(Net::HTTP).to receive(:finish)
  end

  context 'when ensuring CA certs and CRLs' do
    it 'returns an SSLContext with the loaded CA certs and CRLs' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_cacerts).and_return(cacerts)
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_crls).and_return(crls)

      ssl_context = machine.ensure_ca_certificates

      expect(ssl_context[:cacerts]).to eq(cacerts)
      expect(ssl_context[:crls]).to eq(crls)
      expect(ssl_context[:verify_peer]).to eq(true)
    end
  end

  context 'when ensuring a client cert' do
    it 'returns an SSLContext with the loaded CA certs, CRLs, private key and client cert' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_cacerts).and_return(cacerts)
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_crls).and_return(crls)
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_private_key).and_return(private_key)
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_client_cert).and_return(client_cert)

      ssl_context = machine.ensure_client_certificate

      expect(ssl_context[:cacerts]).to eq(cacerts)
      expect(ssl_context[:crls]).to eq(crls)
      expect(ssl_context[:verify_peer]).to eq(true)
      expect(ssl_context[:private_key]).to eq(private_key)
      expect(ssl_context[:client_cert]).to eq(client_cert)
    end
  end

  context 'NeedCACerts' do
    let(:state) { Puppet::SSL::StateMachine::NeedCACerts.new(machine) }

    before :each do
      Puppet[:localcacert] = tmpfile('needcacerts')
    end

    it 'transitions to NeedCRLs state' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_cacerts).and_return(cacerts)

      expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::NeedCRLs)
    end

    it 'loads existing CA certs' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_cacerts).and_return(cacerts)

      st = state.next_state
      expect(st.ssl_context[:cacerts]).to eq(cacerts)
    end

    it 'fetches and saves CA certs' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_cacerts).and_return(nil)
      stub_request(:get, %r{puppet-ca/v1/certificate/ca}).to_return(status: 200, body: cacert_pem)

      st = state.next_state
      expect(st.ssl_context[:cacerts].map(&:to_pem)).to eq(cacerts.map(&:to_pem))
      expect(File).to be_exist(Puppet[:localcacert])
    end

    it "does not verify the server's cert if there are no local CA certs" do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_cacerts).and_return(nil)
      stub_request(:get, %r{puppet-ca/v1/certificate/ca}).to_return(status: 200, body: cacert_pem)
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:save_cacerts)

      expect_any_instance_of(Net::HTTP).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_NONE)

      state.next_state
    end

    it 'raises if the server returns 404' do
      stub_request(:get, %r{puppet-ca/v1/certificate/ca}).to_return(status: 404)

      expect {
        state.next_state
      }.to raise_error(Puppet::Error, /CA certificate is missing from the server/)
    end

    it 'raises if there is a different error' do
      stub_request(:get, %r{puppet-ca/v1/certificate/ca}).to_return(status: [500, 'Internal Server Error'])

      expect {
        state.next_state
      }.to raise_error(Puppet::Error, /Could not download CA certificate: Internal Server Error/)
    end

    it 'raises if CA certs are invalid' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_cacerts).and_return(nil)
      stub_request(:get, %r{puppet-ca/v1/certificate/ca}).to_return(status: 200, body: '')

      expect {
        state.next_state
      }.to raise_error(OpenSSL::X509::CertificateError)
    end

    it 'does not save invalid CA certs' do
      stub_request(:get, %r{puppet-ca/v1/certificate/ca}).to_return(status: 200, body: <<~END)
        -----BEGIN CERTIFICATE-----
        MIIBpDCCAQ2gAwIBAgIBAjANBgkqhkiG9w0BAQsFADAfMR0wGwYDVQQDDBRUZXN0
      END

      state.next_state rescue OpenSSL::X509::CertificateError

      expect(File).to_not exist(Puppet[:localcacert])
    end
  end

  context 'NeedCRLs' do
    let(:ssl_context) { Puppet::SSL::SSLContext.new(cacerts: cacerts)}
    let(:state) { Puppet::SSL::StateMachine::NeedCRLs.new(machine, ssl_context) }

    before :each do
      Puppet[:hostcrl] = tmpfile('needcrls')
    end

    it 'transitions to NeedKey state' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_crls).and_return(crls)

      expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::NeedKey)
    end

    it 'loads existing CRLs' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_crls).and_return(crls)

      st = state.next_state
      expect(st.ssl_context[:crls]).to eq(crls)
    end

    it 'fetches and saves CRLs' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_crls).and_return(nil)
      stub_request(:get, %r{puppet-ca/v1/certificate_revocation_list/ca}).to_return(status: 200, body: crl_pem)

      st = state.next_state
      expect(st.ssl_context[:crls].map(&:to_pem)).to eq(crls.map(&:to_pem))
      expect(File).to be_exist(Puppet[:hostcrl])
    end

    it "verifies the server's certificate when fetching the CRL" do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_crls).and_return(nil)
      stub_request(:get, %r{puppet-ca/v1/certificate_revocation_list/ca}).to_return(status: 200, body: crl_pem)
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:save_crls)

      expect_any_instance_of(Net::HTTP).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)

      state.next_state
    end

    it 'raises if the server returns 404' do
      stub_request(:get, %r{puppet-ca/v1/certificate_revocation_list/ca}).to_return(status: 404)

      expect {
        state.next_state
      }.to raise_error(Puppet::Error, /CRL is missing from the server/)
    end

    it 'raises if there is a different error' do
      stub_request(:get, %r{puppet-ca/v1/certificate_revocation_list/ca}).to_return(status: [500, 'Internal Server Error'])

      expect {
        state.next_state
      }.to raise_error(Puppet::Error, /Could not download CRLs: Internal Server Error/)
    end

    it 'raises if CRLs are invalid' do
      allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_crls).and_return(nil)
      stub_request(:get, %r{puppet-ca/v1/certificate_revocation_list/ca}).to_return(status: 200, body: '')

      expect {
        state.next_state
      }.to raise_error(OpenSSL::X509::CRLError)
    end

    it 'does not save invalid CRLs' do
      stub_request(:get, %r{puppet-ca/v1/certificate_revocation_list/ca}).to_return(status: 200, body: <<~END)
        -----BEGIN X509 CRL-----
        MIIBCjB1AgEBMA0GCSqGSIb3DQEBCwUAMBIxEDAOBgNVBAMMB1Rlc3QgQ0EXDTcw
      END

      state.next_state rescue OpenSSL::X509::CRLError

      expect(File).to_not exist(Puppet[:hostcrl])
    end

    it 'skips CRL download when revocation is disabled' do
      Puppet[:certificate_revocation] = false

      expect_any_instance_of(Puppet::X509::CertProvider).not_to receive(:load_crls)
      expect(Puppet::Rest::Routes).not_to receive(:get_crls)

      state.next_state

      expect(File).to_not exist(Puppet[:hostcrl])
    end
  end

  context 'when ensuring a client cert' do
    context 'in state NeedKey' do
      let(:ssl_context) { Puppet::SSL::SSLContext.new(cacerts: cacerts, crls: crls)}
      let(:state) { Puppet::SSL::StateMachine::NeedKey.new(machine, ssl_context) }

      it 'loads an existing private key and passes it to the next state' do
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_private_key).and_return(private_key)

        st = state.next_state
        expect(st).to be_instance_of(Puppet::SSL::StateMachine::NeedSubmitCSR)
        expect(st.private_key).to eq(private_key)
      end

      it 'loads a matching private key and cert' do
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_private_key).and_return(private_key)
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_client_cert).and_return(client_cert)

        st = state.next_state
        expect(st).to be_instance_of(Puppet::SSL::StateMachine::Done)
      end

      it 'raises if the client cert is mismatched' do
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_private_key).and_return(private_key)
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_client_cert).and_return(cert_fixture('tampered-cert.pem'))

        expect {
          state.next_state
        }.to raise_error(Puppet::SSL::SSLError, %r{The certificate for 'CN=signed' does not match its private key})
      end

      it 'generates a new RSA private key, saves it and passes it to the next state' do
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_private_key).and_return(nil)
        expect_any_instance_of(Puppet::X509::CertProvider).to receive(:save_private_key)

        st = state.next_state
        expect(st).to be_instance_of(Puppet::SSL::StateMachine::NeedSubmitCSR)
        expect(st.private_key).to be_instance_of(OpenSSL::PKey::RSA)
        expect(st.private_key).to be_private
      end

      it 'raises an error if it fails to load the key' do
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:load_private_key).and_raise(OpenSSL::PKey::RSAError)

        expect {
          state.next_state
        }.to raise_error(OpenSSL::PKey::RSAError)
      end
    end

    context 'in state NeedSubmitCSR' do
      let(:ssl_context) { Puppet::SSL::SSLContext.new(cacerts: cacerts, crls: crls)}
      let(:state) { Puppet::SSL::StateMachine::NeedSubmitCSR.new(machine, ssl_context, private_key) }

      def write_csr_attributes(data)
        csr_yaml = tmpfile('state_machine_csr')
        File.write(csr_yaml, YAML.dump(data))
        csr_yaml
      end

      before :each do
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:save_request)
      end

      it 'submits the CSR and transitions to NeedCert' do
        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).to_return(status: 200)

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::NeedCert)
      end

      it 'saves the CSR and transitions to NeedCert' do
        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).to_return(status: 200)

        expect_any_instance_of(Puppet::X509::CertProvider).to receive(:save_request).with(Puppet[:certname], instance_of(OpenSSL::X509::Request))

        state.next_state
      end

      it 'includes DNS alt names' do
        Puppet[:dns_alt_names] = "one,IP:192.168.0.1,DNS:two.com"

        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).with do |request|
          csr = Puppet::SSL::CertificateRequest.from_instance(OpenSSL::X509::Request.new(request.body))
          expect(
            csr.subject_alt_names
          ).to contain_exactly('DNS:one', 'IP Address:192.168.0.1', 'DNS:two.com', "DNS:#{Puppet[:certname]}")
        end.to_return(status: 200)

        state.next_state
      end

      it 'includes CSR attributes' do
        Puppet[:csr_attributes] = write_csr_attributes(
          'custom_attributes' => {
              '1.3.6.1.4.1.34380.1.2.1' => 'CSR specific info',
              '1.3.6.1.4.1.34380.1.2.2' => 'more CSR specific info'
            }
        )

        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).with do |request|
          csr = Puppet::SSL::CertificateRequest.from_instance(OpenSSL::X509::Request.new(request.body))
          expect(
            csr.custom_attributes
          ).to contain_exactly(
                 {'oid' => '1.3.6.1.4.1.34380.1.2.1', 'value' => 'CSR specific info'},
                 {'oid' => '1.3.6.1.4.1.34380.1.2.2', 'value' => 'more CSR specific info'}
               )
        end.to_return(status: 200)

        state.next_state
      end

      it 'includes CSR extension requests' do
        Puppet[:csr_attributes] = write_csr_attributes(
          {
            'extension_requests' => {
              '1.3.6.1.4.1.34380.1.1.31415' => 'pi',
              '1.3.6.1.4.1.34380.1.1.2718'  => 'e',
            }
          }
        )

        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).with do |request|
          csr = Puppet::SSL::CertificateRequest.from_instance(OpenSSL::X509::Request.new(request.body))
          expect(
            csr.request_extensions
          ).to contain_exactly(
                 {'oid' => '1.3.6.1.4.1.34380.1.1.31415', 'value' => 'pi'},
                 {'oid' => '1.3.6.1.4.1.34380.1.1.2718', 'value' => 'e'}
               )
        end.to_return(status: 200)

        state.next_state
      end

      it 'transitions to NeedCert if the server has a requested certificate' do
        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).to_return(status: 400, body: "#{Puppet[:certname]} already has a requested certificate")

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::NeedCert)
      end

      it 'transitions to NeedCert if the server has a signed certificate' do
        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).to_return(status: 400, body: "#{Puppet[:certname]} already has a signed certificate")

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::NeedCert)
      end

      it 'transitions to NeedCert if the server has a revoked certificate' do
        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).to_return(status: 400, body: "#{Puppet[:certname]} already has a revoked certificate")

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::NeedCert)
      end

      it 'raises if the server errors' do
        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).to_return(status: 500)

        expect {
          state.next_state
        }.to raise_error(Puppet::SSL::SSLError, /Failed to submit the CSR, HTTP response was 500/)
      end

      it "verifies the server's certificate when submitting the CSR" do
        stub_request(:put, %r{puppet-ca/v1/certificate_request/#{Puppet[:certname]}}).to_return(status: 200)

        expect_any_instance_of(Net::HTTP).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)

        state.next_state
      end
    end

    context 'in state NeedCert' do
      let(:ca_chain) { [cert_fixture('ca.pem'), cert_fixture('intermediate.pem')] }
      let(:crl_chain) { [crl_fixture('crl.pem'), crl_fixture('intermediate-crl.pem')] }
      let(:ssl_context) { Puppet::SSL::SSLContext.new(cacerts: ca_chain, crls: crl_chain)}
      let(:state) { Puppet::SSL::StateMachine::NeedCert.new(machine, ssl_context, private_key) }

      it 'transitions to Done if the cert is signed and matches our private key' do
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:save_client_cert)
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:save_request)

        stub_request(:get, %r{puppet-ca/v1/certificate/#{Puppet[:certname]}}).to_return(status: 200, body: client_cert.to_pem)

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::Done)
      end

      it 'transitions to Wait if the cert does not match our private key' do
        wrong_cert = cert_fixture('127.0.0.1.pem')
        stub_request(:get, %r{puppet-ca/v1/certificate/#{Puppet[:certname]}}).to_return(status: 200, body: wrong_cert.to_pem)

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::Wait)
      end

      it 'transitions to Wait if the server returns non-200' do
        stub_request(:get, %r{puppet-ca/v1/certificate/#{Puppet[:certname]}}).to_return(status: 404)

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::Wait)
      end

      it "verifies the server's certificate when getting the client cert" do
        stub_request(:get, %r{puppet-ca/v1/certificate/#{Puppet[:certname]}}).to_return(status: 200, body: client_cert.to_pem)
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:save_client_cert)
        allow_any_instance_of(Puppet::X509::CertProvider).to receive(:save_request)

        expect_any_instance_of(Net::HTTP).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)

        state.next_state
      end

      it 'does not save an invalid client cert' do
        stub_request(:get, %r{puppet-ca/v1/certificate/#{Puppet[:certname]}}).to_return(status: 200, body: <<~END)
          -----BEGIN CERTIFICATE-----
          MIIBpDCCAQ2gAwIBAgIBAjANBgkqhkiG9w0BAQsFADAfMR0wGwYDVQQDDBRUZXN0
        END

        state.next_state

        expect(@logs).to include(an_object_having_attributes(message: /Failed to parse certificate: /))
        expect(File).to_not exist(Puppet[:hostcert])
      end

      it 'does not save a mismatched client cert' do
        wrong_cert = cert_fixture('127.0.0.1.pem').to_pem
        stub_request(:get, %r{puppet-ca/v1/certificate/#{Puppet[:certname]}}).to_return(status: 200, body: wrong_cert)

        state.next_state

        expect(@logs).to include(an_object_having_attributes(message: %r{The certificate for 'CN=127.0.0.1' does not match its private key}))
        expect(File).to_not exist(Puppet[:hostcert])
      end

      it 'does not save a revoked client cert' do
        revoked_cert = cert_fixture('revoked.pem').to_pem
        stub_request(:get, %r{puppet-ca/v1/certificate/#{Puppet[:certname]}}).to_return(status: 200, body: revoked_cert)

        state.next_state

        expect(@logs).to include(an_object_having_attributes(message: %r{Certificate 'CN=revoked' is revoked}))
        expect(File).to_not exist(Puppet[:hostcert])
      end
    end

    context 'in state Wait' do
      let(:ssl_context) { Puppet::SSL::SSLContext.new(cacerts: cacerts, crls: crls)}

      it 'exits with 1 if waitforcert is 0' do
        machine = described_class.new(waitforcert: 0)

        expect {
          expect {
            Puppet::SSL::StateMachine::Wait.new(machine, ssl_context).next_state
          }.to exit_with(1)
        }.to output(/Couldn't fetch certificate from CA server; you might still need to sign this agent's certificate \(.*\). Exiting now because the waitforcert setting is set to 0./).to_stdout
      end

      it 'sleeps and transitions to NeedCACerts' do
        machine = described_class.new(waitforcert: 15)

        state = Puppet::SSL::StateMachine::Wait.new(machine, ssl_context)
        expect(state).to receive(:sleep).with(15)

        expect(Puppet).to receive(:info).with(/Couldn't fetch certificate from CA server; you might still need to sign this agent's certificate \(.*\). Will try again in 15 seconds./)

        expect(state.next_state).to be_an_instance_of(Puppet::SSL::StateMachine::NeedCACerts)
      end
    end
  end
end
