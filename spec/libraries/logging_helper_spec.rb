require 'chef_helper'

describe LoggingHelper do
  let(:log) { spy('Chef::Log') }

  before do
    subject.reset
    stub_const('Chef::Log', log)
  end

  context '.messages' do
    it 'starts with no messages' do
      expect(subject.messages).to eq([])
    end
  end

  context '.log' do
    it 'records into .messages' do
      subject.log('one')
      expect(subject.messages).to contain_exactly(Hash)
    end

    it 'records message' do
      subject.log('two')
      expect(subject.messages).to contain_exactly(hash_including(message: 'two'))
    end

    it 'records two messages' do
      subject.log('one')
      subject.log('two')
      expect(subject.messages).to contain_exactly(
        hash_including(message: 'one'),
        hash_including(message: 'two')
      )
    end

    it 'optionally records kind' do
      subject.log('three', kind: :fake)
      expect(subject.messages).to contain_exactly(hash_including(kind: :fake))
    end
  end

  context '.deprecation' do
    it 'calls Chef::Log.warn' do
      subject.deprecation('hello')
      expect(log).to have_received(:warn).with('hello')
    end

    it 'adds the kind :deprecation' do
      subject.deprecation('basic')
      expect(subject.messages).to contain_exactly(hash_including(kind: :deprecation))
    end
  end

  context '.report' do
    it 'prints nothing if nothing happened' do
      expect { subject.report }.not_to output.to_stdout
    end

    it 'prints a deprecation header, then deprecation' do
      subject.deprecation('one')
      expect { subject.report }.to output(/\nDeprecations:\n\none\n/).to_stdout
    end

    it 'prints a deprecation header, then deprecations' do
      subject.deprecation('one')
      subject.deprecation('two')
      expect { subject.report }.to output(/\nDeprecations:\n\none\n---\n\ntwo\n\n/).to_stdout
    end
  end
end
