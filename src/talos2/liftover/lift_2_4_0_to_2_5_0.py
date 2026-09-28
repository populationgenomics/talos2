"""
code for lifting over models from 2.4.0 to 2.5.0
"""


def resultdata(data_dict: dict) -> dict:
    for res in data_dict['results'].values():
        for var in res['variants']:
            # placeholder to represent that the last run did not record this stat
            var['max_confidence'] = -1
            var['confidence_increase'] = False
            # empty placeholder
            var['newly_green'] = ''
    data_dict['version'] = '2.5.0'
    return data_dict
