#!/usr/bin/env python

"""tests for Jon's geometry changes
FIXME : make some tests that the functions do what is expected

"""


import unittest, numpy, os, sys, time
from utilstest import UtilsTest, getLogger
logger = getLogger(__file__)
pyFAI = sys.modules["pyFAI"]
from pyFAI import opencl

from pyFAI import splitBBox
from pyFAI import splitBBoxCSR
if opencl.ocl:
    from pyFAI import ocl_azim_csr

import fabio



ai = pyFAI.load(UtilsTest.getimage("1893/Pilatus1M.poni"))
data = fabio.open(UtilsTest.getimage("1883/Pilatus1M.edf")).data
ai.xrpd_LUT(data, 1000)



class ParameterisedTestCase(unittest.TestCase):
    """ TestCase classes that want to be parameterised should
        inherit from this class.
        From Eli Bendersky's website
        http://eli.thegreenplace.net/2011/08/02/python-unit-testing-parametrized-test-cases/
    """
    def __init__(self, methodName='runTest', param=None):
        super(ParameterisedTestCase, self).__init__(methodName)
        self.param = param

    @staticmethod
    def parameterise(testcase_klass, param=None):
        """ Create a suite containing all tests taken from the given
            subclass, passing them the parameter 'param'.
        """
        testloader = unittest.TestLoader()
        testnames = testloader.getTestCaseNames(testcase_klass)
        suite = unittest.TestSuite()
        for name in testnames:
            suite.addTest(testcase_klass(name, param=param))
        return suite

class TestOpenclCSR(ParameterisedTestCase):

    def test_csr(self):
        workgroup_size = self.param
        N = 1000
        out_ref = pyFAI.splitBBox.histoBBox1d(data, ai._ttha, ai._dttha, bins=N)
        csr = pyFAI.splitBBoxCSR.HistoBBox1d(ai._ttha, ai._dttha, bins=N, unit="2th_deg")
        if not opencl.ocl:
           skip=True
        else:
            try:
                ocl_csr = ocl_azim_csr.OCL_CSR_Integrator(csr.lut, data.size, "ALL", profile=True, block_size=workgroup_size)
                out_ocl_csr = ocl_csr.integrate(data)
            except (opencl.pyopencl.MemoryError, MemoryError):
                logger.warning("Skipping test due to memory error on device")
                skip = True
            else:
                skip = False
        out_cyt_csr = csr.integrate(data)
        cmt = "Testing ocl_csr with workgroup_size= %s" % (workgroup_size)
        logger.debug(cmt)
        if skip:
            for ref, cyth in zip(out_ref, out_cyt_csr):
                self.assertTrue(numpy.allclose(ref, cyth), cmt + ": hist vs csr")
        else:
            for ref, ocl, cyth in zip(out_ref[1:], out_ocl_csr, out_cyt_csr[1:]):
                self.assertTrue(numpy.allclose(ref, ocl), cmt + ": hist vs ocl_csr")
                self.assertTrue(numpy.allclose(ref, cyth), cmt + ": hist vs csr")
                self.assertTrue(numpy.allclose(cyth, ocl), cmt + ": csr vs ocl_csr")
        csr=None
        ocl_csr=None
        out_ocl_csr=None
        out_ref=None

TESTCASES = [8 * 2 ** i for i in range(6)]#[8, 16, 32, 64, 128, 256]


def test_suite_all_OpenCL_CSR():

    testSuite = unittest.TestSuite()
    if opencl.ocl:
        for param in TESTCASES:
            testSuite.addTest(ParameterisedTestCase.parameterise(
                    TestOpenclCSR, param))
    #if no opencl: no test
    return testSuite



if __name__ == '__main__':
    mysuite = test_suite_all_OpenCL_CSR()
    runner = unittest.TextTestRunner()
    runner.run(mysuite)
