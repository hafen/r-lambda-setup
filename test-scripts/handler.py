import ctypes
import json
import os

# use python logging module to log to CloudWatch
# http://docs.aws.amazon.com/lambda/latest/dg/python-logging.html

import logging
logging.getLogger().setLevel(logging.DEBUG)

# must load all shared libraries and set the R environment variables before you can import rpy2

# load R shared libraries from lib dir
for file in os.listdir('lib'):
    if os.path.isfile(os.path.join('lib', file)):
        ctypes.cdll.LoadLibrary(os.path.join('lib', file))

# set R environment variables
os.environ["R_HOME"] = os.getcwd()
os.environ["R_LIBS"] = os.path.join(os.getcwd(), 'site-library')

import rpy2
from rpy2 import robjects

from rpy2.robjects import r

def calculate_stats(x, y):
    """
    @param x: x
    @param y: y
    @return: sum of x and y
    """
    x = robjects.FloatVector(x)
    y = robjects.FloatVector(y)
    # load R library
    # r('library(survival)')
    # assign variables in R
    r.assign('x', x)
    r.assign('y', y)
    # calculate statistics by applying coxph to each record's values
    logging.debug('Calculating stats')
    r("""res <- x^2 + y^2""")
    logging.debug('Done calculating stats')
    # convert results
    r_res = robjects.r['res']
    return r_res

def lambda_handler(event, context):
    x = event['x']
    y = event['y']
    logging.info('Length of x: {0}'.format(len(x)))
    try:
        stats_list = calculate_stats(x, y)
    except rpy2.rinterface.RRuntimeError as e:
        logging.error('Payload: {0}'.format(event))
        logging.error('Error: {0}'.format(e.message))
        # generate a JSON error response that API Gateway will parse and associate with a HTTP Status Code
        error = {}
        error['errorType'] = 'StatisticsError'
        error['httpStatus'] = 400
        error['request_id'] = context.aws_request_id
        error['message'] = e.message.replace('\n', ' ') # convert multi-line message into single line
        raise Exception(json.dumps(error))
    res = {}
    res['statistics_list'] = stats_list
    return res

# lambda_handler({'x': [1], 'y': [2]}, {})
