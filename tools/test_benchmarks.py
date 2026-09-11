#!/usr/bin/env python3
"""Check evidence integrity and comparisons without invoking the compiler."""
import copy
import unittest

from benchmarks import aggregate, compare, inventory, library_comparisons, markdown


class Reports(unittest.TestCase):
    def setUp(self):
        self.catalog = [dict(id='router/test', family='router', iterations=10, bytes_per_op=0)]
        self.samples = [dict(schema=1, compiler='5.5.0', quick=False, seed=seed,
                             results=[dict(self.catalog[0], warmups=3, elapsed_ns=ns * 10,
                                           ns_per_op=ns, allocated_bytes_per_op=0,
                                           minor_collections=0, major_collections=0)])
                        for seed, ns in ((42, 10), (43, 20), (44, 30))]

    def report(self):
        return dict(schema=1, compiler='5.5.0', profile='release', workload_sha256='workload',
                    source_sha256='source', host_fingerprint='host',
                    config=dict(quick=False, family='router', samples=3, seeds=[42, 43, 44]),
                    catalog=self.catalog, samples=self.samples,
                    results=aggregate(self.samples, self.catalog, '5.5.0', False))

    def test_medians_and_spread(self):
        row = self.report()['results'][0]
        self.assertEqual(row['median_ns_per_op'], 20)
        self.assertEqual(row['min_ns_per_op'], 10)
        self.assertEqual(row['max_ns_per_op'], 30)
        self.assertEqual(row['coefficient_of_variation'], .5)
        self.assertIsNone(row['payload_mib_per_second'])

    def test_byte_throughput(self):
        self.catalog[0]['bytes_per_op'] = 1048576
        for sample in self.samples:
            sample['results'][0]['bytes_per_op'] = 1048576
        self.assertEqual(self.report()['results'][0]['payload_mib_per_second'], 50000000)

    def test_catalog_loss_duplication_or_drift(self):
        for rows in ([], self.catalog * 2, [dict(self.catalog[0], family='wrong')]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                inventory(rows)
        self.samples[-1]['results'][0]['iterations'] += 1
        with self.assertRaisesRegex(ValueError, 'catalog differs'):
            self.report()

    def test_invalid_measurements(self):
        for key, value in [('ns_per_op', float('nan')), ('elapsed_ns', float('inf')),
                           ('elapsed_ns', 0), ('allocated_bytes_per_op', -1),
                           ('ns_per_op', 100), ('major_collections', -1), ('warmups', 0)]:
            with self.subTest(key=key, value=value):
                samples = copy.deepcopy(self.samples)
                samples[0]['results'][0][key] = value
                with self.assertRaises(ValueError):
                    aggregate(samples, self.catalog, '5.5.0', False)

    def test_missing_sample_or_wrong_compiler(self):
        with self.assertRaises(ValueError):
            aggregate(self.samples[:1], self.catalog, '5.5.0', False)
        self.samples[-1]['compiler'] = '5.2.0'
        with self.assertRaises(ValueError):
            self.report()

    def test_comparison_and_zero_allocation(self):
        baseline = self.report()
        current = copy.deepcopy(baseline)
        current['source_sha256'] = 'changed-production-code'
        for sample in current['samples']:
            sample['results'][0]['ns_per_op'] *= 2
            sample['results'][0]['elapsed_ns'] *= 2
            sample['results'][0]['allocated_bytes_per_op'] = 8
        current['results'] = aggregate(current['samples'], current['catalog'], '5.5.0', False)
        delta = compare(current, baseline)[0]
        self.assertEqual(delta['time_change_percent'], 100)
        self.assertEqual(delta['allocation_change_bytes_per_op'], 8)
        self.assertIsNone(delta['allocation_change_percent'])

    def test_incompatible_baseline_and_forged_summary(self):
        report = self.report()
        for key in ('schema', 'compiler', 'profile', 'workload_sha256', 'host_fingerprint', 'config'):
            changed = copy.deepcopy(report)
            changed[key] = 'changed'
            with self.subTest(key=key), self.assertRaises(ValueError):
                compare(report, changed)
        changed = copy.deepcopy(report)
        changed['results'][0]['median_ns_per_op'] = 1
        with self.assertRaisesRegex(ValueError, 'retained samples'):
            compare(report, changed)
        changed = copy.deepcopy(report)
        changed['samples'][0]['seed'] = 100
        with self.assertRaisesRegex(ValueError, 'seed order'):
            compare(report, changed)


class LibraryComparisons(unittest.TestCase):
    def fixture(self):
        catalog = [dict(id=f'router/external/lookup/{name}', family='router', comparison='lookup',
                        implementation=name, iterations=10, bytes_per_op=0) for name in ('http-kit', 'routes')]
        samples = [dict(schema=1, compiler='5.5.0', quick=False, seed=i,
                        results=[dict(row, warmups=3, elapsed_ns=ns*10, ns_per_op=ns,
                                      allocated_bytes_per_op=8, minor_collections=0, major_collections=0)
                                 for row, ns in zip(catalog, times)])
                   for i,times in enumerate(((10, 20), (20, 20), (100, 300)))]
        return catalog, samples

    def test_paired_ratios_and_report_labels(self):
        catalog,samples = self.fixture()
        rows = aggregate(samples, catalog, '5.5.0', False)
        comparisons = library_comparisons(rows, samples)
        self.assertEqual(comparisons[0]['sample_time_ratios'], [2, 1, 3])
        self.assertEqual(comparisons[0]['median_other_over_http_kit_time_ratio'], 2)
        report = dict(results=rows, samples=samples, compiler='5.5.0', libraries={'routes':'2.0.0'},
                      library_comparisons=comparisons)
        self.assertIn('Below 1 means the other library was faster', markdown(report))
        self.assertIn('validation work is not equivalent', markdown(report))

    def test_missing_competitor_or_mismatched_work(self):
        catalog,samples = self.fixture()
        rows = aggregate(samples, catalog, '5.5.0', False)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            library_comparisons(rows[:1], samples)
        rows[1]['bytes_per_op'] = 10
        with self.assertRaisesRegex(ValueError, 'sizes differ'):
            library_comparisons(rows, samples)

    def test_comparison_labels_cannot_drift(self):
        catalog,samples = self.fixture()
        samples[0]['results'][0]['implementation'] = 'routes'
        with self.assertRaisesRegex(ValueError, 'id differs'):
            aggregate(samples, catalog, '5.5.0', False)


if __name__ == '__main__':
    unittest.main()
