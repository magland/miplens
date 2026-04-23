classdef NdjsonConsumer < matlab.net.http.io.ContentConsumer
%NDJSONCONSUMER   Stream-parses newline-delimited JSON events from the backend.
%
% Events are single-line JSON objects with a 'type' field:
%   {"type":"reading","path":"..."}   prints a progress line
%   {"type":"done","text":"..."}      captured into resultText
%   {"type":"error","message":"..."}  captured into errorMsg

    properties
        buffer = uint8.empty(0, 1)
        resultText = ''
        errorMsg = ''
    end

    methods
        function [len, stop] = putData(obj, data)
            stop = false;
            len = 0;
            if isempty(data)
                return
            end
            obj.buffer = [obj.buffer; data(:)];

            while true
                nl = find(obj.buffer == uint8(10), 1);
                if isempty(nl)
                    break
                end
                lineBytes = obj.buffer(1:nl - 1);
                obj.buffer = obj.buffer(nl + 1:end);
                if isempty(lineBytes)
                    continue
                end
                lineStr = strtrim(native2unicode(lineBytes', 'UTF-8'));
                if isempty(lineStr)
                    continue
                end
                try
                    evt = jsondecode(lineStr);
                catch
                    continue
                end
                obj.handleEvent(evt);
            end
            len = numel(data);
        end
    end

    methods (Access = protected)
        function bufsize = start(~)
            % Abstract method from ContentConsumer. Returning [] lets MATLAB
            % pick the buffer size. We want smallish buffers so progress
            % events surface promptly rather than waiting for a big fill.
            bufsize = 4096;
        end
    end

    methods (Access = private)
        function handleEvent(obj, evt)
            if ~isstruct(evt) || ~isfield(evt, 'type')
                return
            end
            switch evt.type
                case 'reading'
                    if isfield(evt, 'path')
                        fprintf('  reading %s\n', evt.path);
                    end
                case 'done'
                    if isfield(evt, 'text')
                        obj.resultText = evt.text;
                    end
                case 'error'
                    if isfield(evt, 'message')
                        obj.errorMsg = evt.message;
                    end
            end
        end
    end
end
