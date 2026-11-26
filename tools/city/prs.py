import json, struct, sys
import numpy as np
def read_prs(path):
    b = open(path, "rb").read()
    assert b[:4] == b"PRS2", b[:4]
    (hl,) = struct.unpack_from("<I", b, 4)
    head = json.loads(b[8:8+hl].decode("utf-8"))
    i = 8 + hl
    layers = {}
    for name in head["calques"]:
        (n,) = struct.unpack_from("<I", b, i); i += 4
        lens = np.frombuffer(b, dtype="<u2", count=n, offset=i); i += 2*n
        hts = sol = None
        if name in head["avec_hauteur"]:
            hts = np.frombuffer(b, dtype="<u2", count=n, offset=i); i += 2*n
            sol = np.frombuffer(b, dtype="u1", count=n, offset=i); i += n + (n % 2)
        npts = int(lens.sum())
        xy = np.frombuffer(b, dtype="<i2", count=2*npts, offset=i).reshape(-1, 2); i += 4*npts
        layers[name] = (lens, hts, sol, xy)
    l, h = head["relief"]["l"], head["relief"]["h"]
    relief = np.frombuffer(b, dtype="u1", count=l*h, offset=i).reshape(h, l)
    return head, layers, relief
if __name__ == "__main__":
    head, layers, relief = read_prs(sys.argv[1])
    print({k: v for k, v in head.items() if k not in ("arrondissements", "relief")})
    print("relief", head["relief"], relief.shape, relief.min(), relief.max())
    for k, (lens, hts, sol, xy) in layers.items():
        print(k, "anneaux", len(lens), "points", len(xy), "x", xy[:,0].min(), xy[:,0].max(), "y", xy[:,1].min(), xy[:,1].max(),
              ("h moy %.1f max %d" % (hts.mean(), hts.max())) if hts is not None else "")
    print(head["monuments"])
