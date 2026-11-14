import importlib.util
from pathlib import Path
import unittest
p=Path(__file__).resolve().parents[1]/'Resources/helpers/statusline-limits.py'
if not p.exists(): p=Path('/tmp/pult-fixes/statusline-limits.py')
spec=importlib.util.spec_from_file_location('claude_cache',p);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class CacheTests(unittest.TestCase):
 def test_whitelist_and_timestamp(self):
  out=module.sanitize({'token':'secret','rate_limits':{'five_hour':{'used_percentage':20,'resets_at':1000,'token':'secret'}}},now=42)
  self.assertEqual(out['saved_at'],42);self.assertNotIn('secret',str(out))
 def test_no_false_receipt(self):
  for data in ({},{'rate_limits':{}},{'rate_limits':{'five_hour':{'used_percentage':True}}},{'rate_limits':{'five_hour':{'used_percentage':float('nan')}}}): self.assertIsNone(module.sanitize(data))
if __name__=='__main__': unittest.main()
