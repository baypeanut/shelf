"""Compare pinned Mach-O payloads while excluding only their signing envelope."""
import hashlib
import struct


def payloads(data):
    """Return CPU identities and hashes, independent of signature/fat padding."""
    if data[:4] == b'\xca\xfe\xba\xbe':
        count, = struct.unpack_from('>I', data, 4)
        if not 0 < count <= 16:
            raise ValueError('Invalid universal architecture count')
        result = {}
        for index in range(count):
            cpu, subtype, offset, size, alignment = struct.unpack_from('>IIIII', data, 8 + index * 20)
            if offset < 8 + count * 20 or offset + size > len(data):
                raise ValueError('Invalid universal slice')
            item = payloads(data[offset:offset + size])
            if list(item) != [(cpu, subtype)] or set(item) & set(result):
                raise ValueError('Invalid universal CPU identity')
            result.update(item)
        return result
    if data[:4] != b'\xcf\xfa\xed\xfe' or len(data) < 32:
        raise ValueError('Unexpected pinned Mach-O format')
    _, cpu, subtype, _, count, size, _, _ = struct.unpack_from('<8I', data)
    if not 0 < count <= 1024 or 32 + size > len(data):
        raise ValueError('Invalid load commands')
    cursor = 32
    normalized = bytearray(data)
    signature = None
    linkedit = None
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError('Invalid load command bounds')
        if command == 0x1d:  # LC_CODE_SIGNATURE
            if signature is not None or length != 16:
                raise ValueError('Invalid signing command')
            signature = struct.unpack_from('<II', data, cursor + 8)
            normalized[cursor + 8:cursor + 16] = bytes(8)
        elif command == 0x19 and data[cursor + 8:cursor + 24].rstrip(b'\0') == b'__LINKEDIT':
            if linkedit is not None or length != 72:
                raise ValueError('Invalid linkedit segment')
            _, virtual_size, file_offset, file_size = struct.unpack_from('<QQQQ', data, cursor + 24)
            linkedit = (file_offset, file_size)
            # Code signing changes the signature tail and thus these two sizes.
            normalized[cursor + 32:cursor + 40] = bytes(8)
            normalized[cursor + 48:cursor + 56] = bytes(8)
        cursor += length
    if cursor != 32 + size or signature is None or linkedit is None:
        raise ValueError('Incomplete signed Mach-O')
    offset, signature_size = signature
    if offset < 32 + size or signature_size < 8 or offset + signature_size != len(data):
        raise ValueError('Signature must be the exact file tail')
    if linkedit[0] > offset or sum(linkedit) != len(data):
        raise ValueError('Signature must end the linkedit segment')
    return {(cpu, subtype): hashlib.sha256(normalized[:offset]).digest()}
