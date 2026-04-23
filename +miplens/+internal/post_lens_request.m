function text = post_lens_request(packageName, files, query)
%POST_LENS_REQUEST   POST package files to the miplens backend and stream back progress.

if nargin < 3
    query = '';
end

url = getenv('MIPLENS_BACKEND_URL');
if isempty(url)
    url = 'https://miplens.figurl.workers.dev/lens';
end

payload = struct( ...
    'packageName', packageName, ...
    'query', query, ...
    'files', {arrayToCell(files)});
jsonStr = jsonencode(payload);

msgBody = matlab.net.http.MessageBody();
msgBody.Payload = unicode2native(jsonStr, 'UTF-8');

req = matlab.net.http.RequestMessage( ...
    'POST', ...
    matlab.net.http.HeaderField('Content-Type', 'application/json'), ...
    msgBody);

opts = matlab.net.http.HTTPOptions('ConnectTimeout', 30, 'ResponseTimeout', 600);

consumer = miplens.internal.NdjsonConsumer();
response = send(req, matlab.net.URI(url), opts, consumer);

if response.StatusCode ~= matlab.net.http.StatusCode.OK
    bodyText = consumer.errorMsg;
    if isempty(bodyText) && ~isempty(response.Body) && ~isempty(response.Body.Data)
        bodyText = char(response.Body.Data);
    end
    error('miplens:backendError', ...
          'Backend returned %d: %s', double(response.StatusCode), bodyText);
end

if ~isempty(consumer.errorMsg)
    error('miplens:backendError', '%s', consumer.errorMsg);
end

text = consumer.resultText;

end


function c = arrayToCell(s)
    c = cell(1, numel(s));
    for i = 1:numel(s)
        c{i} = s(i);
    end
end
