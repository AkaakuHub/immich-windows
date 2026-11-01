import http.client
import json
import time
import urllib.error


def read_json(open_response, request):
    if request.get_method() != 'GET':
        raise ValueError('Automatic network retries are limited to reads')
    for attempt in range(3):
        delay = 2 ** (attempt + 1)
        try:
            with open_response(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            headers = error.headers
            limited = error.code in (403, 429)
            if limited:
                if headers.get('Retry-After', '').isdigit():
                    delay = max(delay, int(headers['Retry-After']))
                elif headers.get('X-RateLimit-Remaining') == '0' and headers.get('X-RateLimit-Reset', '').isdigit():
                    delay = max(delay, int(headers['X-RateLimit-Reset']) - time.time() + 1)
                else:
                    raise
            elif error.code not in (408, 500, 502, 503, 504):
                raise
            if attempt == 2 or delay > 30:
                raise
            error.close()
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead):
            if attempt == 2:
                raise
        print(f'Temporary GitHub read failure; retry {attempt + 1}/2 in {delay:g}s.')
        time.sleep(delay)
