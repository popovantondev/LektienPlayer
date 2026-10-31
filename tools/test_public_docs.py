"""Regression checks for documentation metadata; never starts the application."""
import copy, importlib.util, json, tempfile, unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('public_docs',Path(__file__).with_name('check_public_docs.py'))
docs=importlib.util.module_from_spec(spec);spec.loader.exec_module(docs)
class PublicDocsTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.previous=docs.ROOT;docs.ROOT=Path(self.temp.name)
        self.data={'repo':'Example','name':'Example','version':'1.0','platform':'macOS','tag':None,'status':'source','release_url':None,'source_url':'https://github.com/popovantondev/Example','help_url':'https://popovantondev.github.io/Example/Guide-{lang}.html','feedback_url':'https://github.com/popovantondev/Example/issues/new/choose','downloads':[],'assets':[],'checksums':[],'description':dict.fromkeys(docs.LANGS,'An application.'),'requirements':dict.fromkeys(docs.LANGS,'Source setup.'),'start':dict.fromkeys(docs.LANGS,'Read the guide.'),'version_files':[{'path':'VERSION','pattern':r'^(\S+)$'}]}
        (docs.ROOT/'VERSION').write_text('1.0')
        self.files={'README.md':docs.markdown(self.data,'en')}
        (docs.ROOT/'README.md').write_text(self.files['README.md'],encoding='utf-8')
    def tearDown(self):docs.ROOT=self.previous;self.temp.cleanup()
    def check(self):return docs.validate(self.data,self.files)
    def test_valid_metadata(self):self.assertEqual(self.check(),[])
    def test_summary_drift(self):
        (docs.ROOT/'README.md').write_text('changed');self.assertTrue(any('regenerate' in e for e in self.check()))
    def test_version_drift(self):
        (docs.ROOT/'VERSION').write_text('2.0');self.assertTrue(any('version mismatch' in e for e in self.check()))
    def test_raw_html_destination(self):
        self.data['help_url']='https://github.com/popovantondev/Example/blob/main/Guide-{lang}.html';self.assertTrue(any('published HTML' in e for e in self.check()))
    def test_source_only_download(self):
        self.data['downloads']=['app.zip'];self.assertTrue(any('source-only' in e for e in self.check()))
    def test_missing_image(self):
        (docs.ROOT/'README.md').write_text(self.files['README.md']+'\n![Example](missing.png)',encoding='utf-8');self.assertTrue(any('missing image' in e for e in self.check()))
    def test_missing_local_document(self):
        (docs.ROOT/'README.md').write_text(self.files['README.md']+'\n[Setup](missing.md)',encoding='utf-8');self.assertTrue(any('missing local link' in e for e in self.check()))
    def test_production_credit(self):
        (docs.ROOT/'README.md').write_text(self.files['README.md']+'\nCreated with ChatGPT',encoding='utf-8');self.assertTrue(any('production content' in e for e in self.check()))
    def test_functional_codex_reference_allowed(self):
        text=self.files['README.md']+'\nRuns approved tasks through Codex.';self.files['README.md']=text;(docs.ROOT/'README.md').write_text(text,encoding='utf-8');self.assertEqual(self.check(),[])
    def test_internal_instruction_file(self):
        (docs.ROOT/'AGENTS.md').write_text('Internal notes');self.assertTrue(any('Internal document' in e for e in self.check()))
    def test_missing_translation(self):
        del self.data['description']['ru'];self.assertTrue(any('incomplete localization' in e for e in self.check()))
    def test_release_tag_destination(self):
        self.data.update(tag='v1.0',release_url='https://github.com/popovantondev/Example/releases/latest',status='release');self.assertTrue(any('URL/tag mismatch' in e for e in self.check()))
class SharedDistributionTests(PublicDocsTests):
    def set_shared(self):
        release='https://github.com/popovantondev/Bundle/releases/tag/v2.0'
        self.data.update(status='preview',tag=None,release_url=release,shared_distribution={'repo':'Bundle','version':'2.0','tag':'v2.0','release_url':release,'application_versions':{'Example':'1.0'}})
    def test_shared_release_keeps_application_version(self):
        self.set_shared();self.assertEqual(self.check(),[]);self.assertEqual(docs.release_target(self.data),('Bundle','v2.0'))
    def test_unmarked_foreign_release_rejected(self):
        self.set_shared();del self.data['shared_distribution'];self.assertTrue(any('requires shared_distribution' in e for e in self.check()))
    def test_wrong_application_version_rejected(self):
        self.set_shared();self.data['shared_distribution']['application_versions']['Example']='2.0';self.assertTrue(any('application version mismatch' in e for e in self.check()))
    def test_shared_tag_cannot_be_own_tag(self):
        self.set_shared();self.data['tag']='v1.0';self.assertTrue(any('impersonate' in e for e in self.check()))
    def test_shared_asset_must_belong_to_declared_release(self):
        self.set_shared();self.data['assets']=[{'name':'setup.exe','url':'https://example.invalid/setup.exe'}];self.assertTrue(any('asset URL mismatch' in e for e in self.check()))
    def test_invalid_shared_repository_rejected(self):
        self.set_shared();self.data['shared_distribution']['repo']='../Other';self.assertTrue(any('invalid shared' in e for e in self.check()))

class NetworkRetryTests(unittest.TestCase):
    def test_transient_connection_error_is_retried(self):
        import io
        from unittest.mock import patch
        with patch.object(docs.urllib.request, 'urlopen', side_effect=[ConnectionResetError('reset'), io.BytesIO(b'ok')]) as request, patch.object(docs.time, 'sleep'):
            self.assertEqual(docs.fetch_bytes('https://example.invalid'), b'ok')
            self.assertEqual(request.call_count, 2)

    def test_not_found_is_not_retried(self):
        from unittest.mock import patch
        error=docs.urllib.error.HTTPError('https://example.invalid', 404, 'Not found', {}, None)
        with patch.object(docs.urllib.request, 'urlopen', side_effect=error) as request, patch.object(docs.time, 'sleep'):
            with self.assertRaises(docs.urllib.error.HTTPError):
                docs.fetch_bytes('https://example.invalid')
            self.assertEqual(request.call_count, 1)

    def test_temporary_server_error_is_retried(self):
        import io
        from unittest.mock import patch
        error=docs.urllib.error.HTTPError('https://example.invalid', 503, 'Unavailable', {}, None)
        with patch.object(docs.urllib.request, 'urlopen', side_effect=[error, io.BytesIO(b'ok')]), patch.object(docs.time, 'sleep'):
            self.assertEqual(docs.fetch_bytes('https://example.invalid'), b'ok')

    def test_persistent_connection_error_still_fails(self):
        from unittest.mock import patch
        with patch.object(docs.urllib.request, 'urlopen', side_effect=ConnectionResetError('reset')) as request, patch.object(docs.time, 'sleep'):
            with self.assertRaises(ConnectionResetError):
                docs.fetch_bytes('https://example.invalid')
            self.assertEqual(request.call_count, 3)

if __name__=='__main__':unittest.main()
